#!/usr/bin/env bash
# 發佈前的去識別化檢查。
#
# 用法: ./scripts/check-sanitized.sh
#
# 關鍵字清單放在 repo 根目錄的 .denylist（已列入 .gitignore，不會被提交），
# 每行一個 extended regex，例如公司網域、內網網段、主機命名規則、人名。
# 清單本身就是敏感資訊，所以絕不能 commit。

set -euo pipefail
cd "$(dirname "$0")/.."

rc=0

if [ ! -f .denylist ]; then
  echo "找不到 .denylist，請先建立（每行一個 regex）" >&2
  exit 2
fi

echo "--- 1. 關鍵字掃描 (.denylist) ---"
while IFS= read -r pattern; do
  [ -z "$pattern" ] || [[ "$pattern" == \#* ]] && continue
  if git grep --untracked -nIiE -- "$pattern" -- . ':!scripts/check-sanitized.sh' ; then
    rc=1
  fi
done < .denylist

echo "--- 2. 非範例用的私有 IP ---"
# 允許文件常用的 192.168.x.x 與 10.0.0.x，其他私有網段一律視為可疑
if git grep --untracked -nIE '\b(10\.([1-9][0-9]?|[1-9][0-9]{2})\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)\b' ; then
  rc=1
fi

echo "--- 3. 機密檔案類型 ---"
if git ls-files -co --exclude-standard | grep -E '\.(pem|key|pfx|p12|crt|kubeconfig)$|private-key' ; then
  rc=1
fi

echo "--- 4. gitleaks (含 git 歷史) ---"
if command -v gitleaks >/dev/null; then
  gitleaks detect --source . --redact || rc=1
else
  echo "未安裝 gitleaks，略過（CI 上會跑）"
fi

[ "$rc" -eq 0 ] && echo "✅ 通過" || echo "❌ 有命中項目，請處理後再發佈"
exit "$rc"
