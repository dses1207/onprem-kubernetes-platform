# 節點關機保護

[English](README.md)

防止節點關機時 Longhorn volume 的 ext4 檔案系統損毀。

## 為什麼需要

RKE2/k3s 的關機流程不會優雅地 detach Longhorn volume
（[longhorn#7206](https://github.com/longhorn/longhorn/issues/7206)，maintainer 確認屬設計缺口）。

損毀過程：
1. 關機開始，containerd / instance-manager 被停掉
2. engine 進程消失，但 ext4 仍掛載，page cache 裡還有 dirty page
3. iSCSI 連線中斷，kernel 試圖 flush superblock → I/O error
4. ext4 轉為 read-only，但 metadata 已寫到一半
5. 重開機後 journal replay 無法修復 → `fsck` 失敗 → PVC 掛不起來

此時 Longhorn 仍顯示 `robustness: healthy`，因為 block layer 看不到上層 ext4 的狀態。

## 兩道防線

K8s 官方立場是兩者互補，不是二選一：

| 防線 | 檔案 | 涵蓋情境 |
|---|---|---|
| kubelet graceful shutdown | `kubelet-shutdown-config.yaml`<br>`60-shutdown-grace.yaml` | 非預期關機（`reboot`、`shutdown`） |
| 關機自動 drain | `rke2-drain-on-shutdown.service`<br>`rke2-drain-node.sh` | 同上，另外把 pod 搬走 |

兩者都無法涵蓋 `reboot -f`、硬體斷電、VM 強制關機，因為這些會直接繞過 systemd inhibitor lock。
計畫性維護仍應手動 drain。

## InhibitDelayMaxSec 的限制

graceful node shutdown 依賴 systemd inhibitor lock，而 `/etc/systemd/logind.conf` 的
`InhibitDelayMaxSec` **預設只有 30 秒**，會直接截斷 kubelet 的 `shutdownGracePeriod`。
設了 180s 但沒改 logind，實際上只會拿到 30s。

`systemd-logind` 不支援 reload，restart 又會踢掉所有 SSH session，
所以安裝腳本只寫入設定檔，新值在節點重開機後生效。

```bash
systemctl show systemd-logind -p InhibitDelayMaxUSec --value
# 30s  = 尚未生效
# 5min = 已生效
```

## 部署

```bash
sudo bash install-shutdown-protection.sh   # 每台節點執行，可重複執行
```

腳本不會自動重啟 rke2，結尾會印出在維護窗口要手動執行的 drain / restart / uncordon 步驟。
