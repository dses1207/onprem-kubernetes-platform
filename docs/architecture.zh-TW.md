# 架構說明

[English](architecture.md)

## 1. 整體流程

一個請求從使用者到資料，依序經過：

```
使用者 → DNS (*.example.com → VIP) → kube-vip → Traefik → Service → Pod → PVC (Longhorn) → 本機磁碟
                                                                         ↘ 定期備份到 S3
```

叢集本身則由 Rancher 統一佈建與升級，etcd 快照同樣送到 S3。

## 2. 各層細節

### 2.1 入口：DNS + kube-vip + Traefik

- 每個系統一筆 `<name>.example.com` 的 A 紀錄，全部指向同一個 VIP，由 Traefik 依 Host 分流。
- 地端沒有雲端 LB，用 kube-vip 做 L2 ARP 宣告 VIP，並兼任 `type: LoadBalancer` 的 IP 配發（從固定位址池切出）。
- Traefik 設預設 TLSStore（萬用憑證），Ingress 只需寫 `tls.hosts`，不必每個 namespace 都放憑證；80 一律轉 443。
- 選 Traefik 而非 ingress-nginx：ingress-nginx 上游已宣布退役，RKE2 新版也預設改用 Traefik。

### 2.2 運算：節點角色與排程

| 角色 | 數量 | Taint | 用途 |
|---|---|---|---|
| control-plane / etcd | 3 | control-plane | API、etcd |
| infra worker | 3 | `node-role/infra:NoSchedule` | 監控、日誌、MQ 等平台元件 |
| app worker | 3 | 無 | 一般業務 workload |
| GPU worker | 1+ | 依需求 | 推論 / 訓練 |

經驗：scheduler 看的是 requests 而非實際用量。曾經發生節點 CPU 實際只用 5%、requests 卻達 68%，
cordon 一台之後 CronJob 全部 Pending。該調整的是 requests，而不是加機器。

### 2.3 儲存：Longhorn

- 以 PVC label 加入備份群組，不必每次改 Longhorn 設定（見 `platform/longhorn/`）：
  - `db` 群組：每 6 小時 snapshot（保留 4 份）＋每日 S3 備份（保留 7 份）
  - `daily` 群組：每日 S3 備份（保留 3 份）
- 節點關機保護（見 `platform/node-shutdown-protection/`）：RKE2 關機流程不會優雅地 detach volume，
  因此用 kubelet graceful shutdown ＋ 關機前 drain 兩道防線。
- 注意 VM 從同一份映像複製時，`longhorn-disk.cfg` 的 diskUUID 會重複，見 [postmortem 0002](postmortems/0002-network-partition-longhorn-fs-corruption.zh-TW.md)。

### 2.4 資料庫：CloudNativePG

- 3 instances，同步 HA replication slot，WAL 持續歸檔到 S3。
- 必設 `max_slot_wal_keep_size`：否則某個 replica 長期掛掉時，它的 slot 會無限保留 WAL，把 WAL 卷寫滿。

### 2.5 GPU：DRA

- GPU Operator 使用 DRA 模式，Pod 改用 `resourceClaims` 申請 GPU，不再寫 `nvidia.com/gpu: 1`。
- 可用 CEL selector 指定特定卡（例如排除節點上被其他程式佔用的卡）。
- 推論與訓練以 PriorityClass 區分，資源吃緊時先驅逐訓練（見 `platform/scheduling/`）。

### 2.6 可觀測性

- Metrics：kube-prometheus-stack，Alertmanager 透過轉接服務推送到團隊聊天室。
- Logs：fluent-bit DaemonSet → Loki。tolerations 必須涵蓋所有節點（包含帶 taint 的 infra／儲存節點），
  否則出事時剛好查不到儲存元件的 log。

## 3. 災難復原

| 情境 | 做法 |
|---|---|
| etcd quorum 遺失 | Rancher `etcdSnapshotRestore`，從 S3 最新快照還原 |
| Volume 檔案系統損毀 | 先 snapshot 保全現場 → 從健康副本或 S3 備份還原 |
| 單一節點長期故障 | 移除 machine、補新節點；資料庫靠 HA 自動切換 |
