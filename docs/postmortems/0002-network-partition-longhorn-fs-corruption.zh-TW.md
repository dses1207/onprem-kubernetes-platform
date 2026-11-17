# Postmortem 0002：網路局部分區導致資料庫檔案系統損毀，並連鎖造成 WAL 寫滿

[English](0002-network-partition-longhorn-fs-corruption.md)

| 項目 | 內容 |
|---|---|
| 影響範圍 | 正式叢集多個有狀態服務；認證服務的資料庫連帶停擺 |
| 持續時間 | 網路中斷約 18 分鐘；資料修復與二次事故處理共數天 |
| 嚴重度 | 高 |

## 摘要

交換器層級的問題讓兩台 worker 與部分 control-plane 互相不通，持續超過 5 分鐘。
controller-manager 把這兩台標成 unreachable，taint-based eviction 在 300 秒後把節點上的
Longhorn instance-manager 標記刪除。網路一恢復，kubelet 收到指令就把它砍掉，
節點上所有 volume engine 隨之消失，尚未寫入的資料遺失，ext4 損毀。

五天後又發生二次事故：損毀的資料庫 replica 一直沒修好，它的 replication slot 卡住 WAL 不能回收，
最終把 primary 的 WAL 卷寫滿，整個資料庫叢集 PANIC 停機。

## 時間線（相對時間）

| T+ | 事件 |
|---|---|
| 0m | `worker-2`、`worker-4` 與部分 control-plane 之間 `no route to host`（L2/ARP 不通） |
| 1m | 一台 control-plane 的 etcd leader election 失敗，rke2-server 自行退出 |
| 5m | 兩台 worker 的 instance-manager 因 toleration 只有 300s，被 taint-eviction-controller 標刪除 |
| 18m | 網路恢復；kubelet 立刻砍掉 instance-manager，iSCSI target 消失 |
| 20m | kernel 出現 `lost sync page write`；資料庫 Pod 換節點後 fsck 失敗 |
| Day 5 | CNPG primary 出現 `PANIC: could not write to file "pg_wal/xlogtemp": No space left on device` |

## 根因

### 直接原因：儲存引擎被 eviction 殺掉
Longhorn instance-manager 預設的 `node.kubernetes.io/unreachable` toleration 只有 300 秒。
對儲存元件來說，「網路暫時不通」被當成「節點死了」處理，反而造成實際的資料損毀。

### 深層原因：diskUUID 重複
節點是從同一份 VM 映像複製出來的，6 台的 `/var/lib/longhorn/longhorn-disk.cfg` diskUUID 完全相同。
Longhorn 各節點不斷互搶副本歸屬，45 秒內 114 個 replica 有 98 個的 `nodeID` 在跳動；
attach 時副本程序可能起在錯的節點，讀到空的或過期的資料。
這也讓「逐台 evict 修復」這條路不可行。

### 二次事故：replication slot 無上限
- 損毀的 replica 一直起不來，它的 HA replication slot 停在舊的 LSN。
- `max_slot_wal_keep_size` 未設定（預設 `-1`，無上限）。
- `archive_timeout = 5min`：即使閒置，每天也會產生約 4.6 GB 的 WAL，20 GiB 卷大約撐 4–5 天。
- 資料庫 Cluster `Ready=False` 掛了 5 天，沒有告警。

## 排查重點

1. 多個 Pod 同時重啟並出現 fsck 錯誤時，先看各節點同一時段的 syslog，確認是不是網路問題：
   ```bash
   kubectl get --raw /api/v1/nodes/<node>/proxy/logs/syslog | grep -i "no route to host"
   ```
2. Longhorn 顯示 `robustness: healthy` 不代表檔案系統沒壞，因為 block layer 看不到上層 ext4 的狀態。
3. 檢查 WAL 為何不回收：歸檔正常、standby 有在 streaming，最後剩下的嫌疑就是 slot：
   ```sql
   SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
   FROM pg_replication_slots;
   ```

## 修復

### 資料庫 volume

1. 動手前先對所有相關 volume 做 snapshot。
2. 找出 head 寫得最晚的健康副本，複製到隔離目錄掛起來，抽出 pgdata，確認 PostgreSQL crash recovery 成功。
3. 從 S3 還原時要指定 `backupTargetName`，否則會還原出空的 volume，CSI 還會自動 mkfs。

### WAL 寫滿

1. Snapshot 保全現場。
2. 擴大 `walStorage`：operator 在磁碟已滿的狀態下不會自己擴 PVC，需要手動 patch PVC。
3. 把損毀 replica 的 PV 改成 `Retain`，再刪除該 Pod 與 PVC。operator 會自動建立新 instance 並移除舊 slot。
4. WAL 從 20 GB 降到 600 MB，3/3 healthy。
5. 設定 `max_slot_wal_keep_size = 10GB`（reload 即可生效）。

## 預防措施

- [ ] 重新產生每個節點的 Longhorn diskUUID；VM 映像流程加入「清除 longhorn-disk.cfg」步驟。
- [x] 資料庫設定 `max_slot_wal_keep_size`。
- [ ] 新增告警：CNPG Cluster `Ready=False` 超過 15 分鐘、WAL 卷使用率 > 70%。
- [ ] 單實例資料庫改為 HA，或至少確認 S3 備份每日成功。
- [x] 節點關機保護（見 `platform/node-shutdown-protection/`）。
- [ ] 評估調整儲存元件的 unreachable toleration，並在網路層面加強監控（交換器、ARP）。
