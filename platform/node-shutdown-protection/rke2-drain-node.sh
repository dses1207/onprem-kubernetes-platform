#!/bin/bash
# 關機前 drain 本節點。由 rke2-drain-on-shutdown.service 的 ExecStop 呼叫。
#
# 部署位置: /usr/local/bin/rke2-drain-node.sh
#
# 設計取捨:
#  - 「不」使用 --force: --force 會刪掉無 controller 管理的裸 pod,
#    那些 pod 一旦刪除就不會回來, 可能造成資料遺失。寧可 drain 失敗
#    也不要靜默毀掉東西 —— 失敗時仍有 shutdownGracePeriod 這道防線。
#  - 「不」使用 --disable-eviction: 必須尊重 PodDisruptionBudget,
#    否則可能一次打掉某服務的所有副本。
#  - timeout 240s: 需小於 service 的 TimeoutStopSec(270s), 留收尾餘裕。

set -uo pipefail

NODE=$(hostname)
LOG="logger -t rke2-drain-shutdown"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH="/var/lib/rancher/rke2/bin:${PATH}"

# server 節點用 rke2.yaml; agent 節點沒有該檔, 改用 kubelet 的 kubeconfig
if [ ! -r "$KUBECONFIG" ]; then
  KUBECONFIG=/var/lib/rancher/rke2/agent/kubelet.kubeconfig
  export KUBECONFIG
fi

KUBECTL=$(command -v kubectl 2>/dev/null || echo /var/lib/rancher/rke2/bin/kubectl)

if [ ! -x "$KUBECTL" ] || [ ! -r "$KUBECONFIG" ]; then
  $LOG "找不到 kubectl 或 kubeconfig, 略過 drain (kubectl=$KUBECTL kubeconfig=$KUBECONFIG)"
  exit 0    # 不擋關機
fi

# API server 連得到才做 —— 整叢集同時關機時這裡會失敗, 直接放行
if ! "$KUBECTL" --request-timeout=15s get node "$NODE" >/dev/null 2>&1; then
  $LOG "API server 不可達, 略過 drain"
  exit 0
fi

$LOG "開始 drain 節點 $NODE"

"$KUBECTL" drain "$NODE" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=240s \
  --skip-wait-for-delete-timeout=60 \
  2>&1 | $LOG

rc=${PIPESTATUS[0]}
if [ "$rc" -eq 0 ]; then
  $LOG "drain 成功, 節點已淨空"
else
  # 不 exit 非零 —— 讓機器繼續關機, 否則會卡住無法重開
  $LOG "drain 未完成 (rc=$rc), 仍繼續關機; 請於重開後檢查 journalctl -k -b -1 是否有 EXT4-fs 錯誤"
fi

exit 0
