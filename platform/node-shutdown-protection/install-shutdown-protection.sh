#!/bin/bash
# 部署節點關機保護: graceful node shutdown + 關機自動 drain。
#
# 用法 (每台節點以 root 執行):
#   sudo bash install-shutdown-protection.sh
#
# 冪等: 可重複執行。
#
# 這支腳本做四件事:
#   1. 調高 systemd logind 的 InhibitDelayMaxSec (否則 kubelet 只拿得到 30s)
#   2. 安裝 kubelet 關機寬限期設定
#   3. 安裝關機自動 drain 的 systemd unit (第二道防線)
#   4. 印出後續需人工執行的步驟 (重啟 rke2 才會生效)
#
# ⚠️ 本腳本「不會」自動重啟 rke2 —— 那會中斷節點上的 workload。
# 請在 drain 過該節點後再手動重啟, 見結尾提示。

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "=== [$(hostname)] 部署關機保護 ==="

# ---------- 1. systemd logind: 放寬 inhibitor lock 上限 ----------
# K8s graceful node shutdown 靠 systemd inhibitor lock 延遲關機。
# InhibitDelayMaxSec 預設 30s, 會把 kubelet 的 shutdownGracePeriod 截斷。
LOGIND=/etc/systemd/logind.conf
DESIRED_INHIBIT=300    # 需 >= kubelet 的 shutdownGracePeriod(180s), 留餘裕

echo "--- 1. 設定 logind InhibitDelayMaxSec=${DESIRED_INHIBIT}s ---"
echo "    變更前: $(grep -E '^\s*InhibitDelayMaxSec' "$LOGIND" 2>/dev/null || echo '(未設定, 預設 30s)')"
[ -f "${LOGIND}.bak" ] || cp -a "$LOGIND" "${LOGIND}.bak"

if grep -qE "^\s*#?\s*InhibitDelayMaxSec=" "$LOGIND"; then
  sed -i -E "s|^\s*#?\s*InhibitDelayMaxSec=.*|InhibitDelayMaxSec=${DESIRED_INHIBIT}|" "$LOGIND"
else
  sed -i "/^\[Login\]/a InhibitDelayMaxSec=${DESIRED_INHIBIT}" "$LOGIND"
fi
echo "    變更後: $(grep -E '^\s*InhibitDelayMaxSec' "$LOGIND")"

# systemd-logind 的 CanReload=no —— 它「不支援」reload, 只能 restart。
# 但 restart systemd-logind 會踢掉所有 SSH session, 不適合在此自動執行。
#
# 好消息: 這不影響部署流程。階段二本來就要重啟 rke2 服務, 而節點下次
# 重開機時 logind 必然重新載入設定 —— 屆時新值自動生效。
# 若要「立即」生效且可承受斷線, 手動執行: sudo systemctl restart systemd-logind
CUR_INHIBIT=$(systemctl show systemd-logind -p InhibitDelayMaxUSec --value 2>/dev/null)
echo "    設定檔已更新; logind 執行中的值 = ${CUR_INHIBIT:-未知}"
echo "    (logind 不支援 reload, 新值於重啟 logind 或節點重開機後生效)"

# ---------- 2. kubelet 關機寬限期 ----------
echo "--- 2. 安裝 kubelet 設定 ---"
install -m 0600 -o root -g root \
  "${SRC_DIR}/kubelet-shutdown-config.yaml" \
  /etc/rancher/rke2/kubelet-shutdown-config.yaml
echo "    -> /etc/rancher/rke2/kubelet-shutdown-config.yaml"

mkdir -p /etc/rancher/rke2/config.yaml.d
install -m 0600 -o root -g root \
  "${SRC_DIR}/60-shutdown-grace.yaml" \
  /etc/rancher/rke2/config.yaml.d/60-shutdown-grace.yaml
echo "    -> /etc/rancher/rke2/config.yaml.d/60-shutdown-grace.yaml"
echo "    (編號 60 > Rancher 的 50-rancher.yaml, 不會互相覆蓋)"

# ---------- 3. 關機自動 drain (第二道防線) ----------
echo "--- 3. 安裝關機 drain unit ---"
install -m 0755 -o root -g root \
  "${SRC_DIR}/rke2-drain-node.sh" /usr/local/bin/rke2-drain-node.sh
install -m 0644 -o root -g root \
  "${SRC_DIR}/rke2-drain-on-shutdown.service" \
  /etc/systemd/system/rke2-drain-on-shutdown.service
systemctl daemon-reload
systemctl enable rke2-drain-on-shutdown.service >/dev/null 2>&1
systemctl start  rke2-drain-on-shutdown.service  >/dev/null 2>&1
echo "    unit 狀態: $(systemctl is-enabled rke2-drain-on-shutdown.service 2>&1) / $(systemctl is-active rke2-drain-on-shutdown.service 2>&1)"

# ---------- 4. 後續步驟 ----------
SVC=$(systemctl is-active rke2-server >/dev/null 2>&1 && echo rke2-server || echo rke2-agent)
cat <<MSG

=== [$(hostname)] 檔案部署完成 ===

⚠️ kubelet 設定「尚未生效」—— 需重啟 ${SVC}, 這會中斷本機 workload。
請在維護窗口依序執行:

  kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data --timeout=300s
  sudo systemctl restart ${SVC}
  kubectl uncordon $(hostname)

驗證生效 (應顯示 180s / 60s, 而非 0s):
  sudo grep -A3 shutdownGracePeriod /var/lib/rancher/rke2/agent/etc/kubelet.conf 2>/dev/null
  kubectl get --raw "/api/v1/nodes/$(hostname)/proxy/configz" | grep -o '"shutdownGracePeriod[^,]*'

MSG
