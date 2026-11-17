# Postmortem 0001：新增 etcd 節點拖垮整個叢集 API

[English](0001-etcd-quorum-loss-on-slow-disk.md)

| 項目 | 內容 |
|---|---|
| 影響範圍 | AI 叢集 API 無法使用，所有部署與排程停擺 |
| 持續時間 | 約 1 小時 |
| 嚴重度 | 高（控制平面完全中斷，既有 Pod 仍持續運行） |

## 摘要

為了汰換單節點叢集的主機，把新主機以 `etcd + control-plane + worker` 角色加入。
新主機的根碟是低轉速 SMR 硬碟，又同時在編譯 GPU 驅動，etcd 成員始終起不來。
叢集從 1 票變成 2 票，少了一票就失去 quorum，連原本健康的節點 API 也一起停擺。

## 時間線（相對時間）

| T+ | 事件 |
|---|---|
| 0m | 在 Rancher 以三種角色註冊新節點 `node-b` |
| 5m | `node-b` 的 `rke2-server` 卡在 `activating`，系統負載 9–14 |
| 8m | Rancher 顯示 cluster health check failed；原節點 `node-a` 的 API 也無回應 |
| 20m | 確認 etcd 成員數 2、健康 1，失去 quorum |
| 40m | 刪除 `node-b` 的 machine 物件，觸發 `etcdSnapshotRestore` |
| 55m | `node-a` 完成 cluster-reset，API 恢復 |

## 根因

1. etcd 對磁碟 fsync 延遲極度敏感。SMR 硬碟加上同時進行的 DKMS 編譯，讓 etcd 根本無法完成啟動。
2. 1 → 2 是最脆弱的擴充步驟。2 個成員的 quorum 是 2，任何一台有問題整個叢集就停；
   這段期間的容錯能力比單節點還差。
3. 加入節點前沒有任何硬體檢查。

## 排查過程中的岔路

- 還原一開始卡在 Shutdown 階段：先前為了減輕負載，手動停掉了 `node-b` 的 `rancher-system-agent`，
  Rancher 等不到它回報 rke2 已停止。刪除該 machine 物件後才繼續。
- 操作端工作站記憶體不足，數個背景 SSH 被 OOM 砍掉。對慢節點要用短指令、長 timeout，減少並行。

## 修復

```yaml
# 對 cluster 物件設定 (Rancher provisioning v2)
spec:
  rkeConfig:
    etcdSnapshotRestore:
      name: <最新的 S3 快照名稱>
      generation: 1
      restoreRKEConfig: none
```

## 預防措施

- [x] 新增節點前的硬性檢查（不通過就不准加入）：
  - 根碟 `cat /sys/block/<dev>/queue/rotational` 必須為 `0`
  - 系統負載低於門檻、GPU 驅動已就緒、自動更新已停用
- [x] 汰換節點時，新節點 Ready 後立刻移除舊節點，縮短 2 票期。
- [ ] 用 `fio` 量 fsync 延遲（etcd 官方建議 WAL fsync 99th percentile < 10ms）
- [ ] 長期目標：control-plane 一律 3 台，讓單台失效不影響 quorum。
- [x] Runbook 補上：API 掛掉時先確認每台 etcd 節點的 system-agent 還活著，或先刪掉壞節點的 machine。
