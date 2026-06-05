#!/usr/bin/env bash
# verify/05-sandbox-cold.sh
# 目标: 首次 tool_call 触发 E2B sandbox 唤起 ≤ 3s
# 前置: FASTCLAW_SANDBOX_ENABLED=true. 若 ConfigMap 未启用, 跳过.

set -euo pipefail

ENABLED=$(kubectl -n fastclaw get cm fastclaw-config -o jsonpath='{.data.FASTCLAW_SANDBOX_ENABLED}')
if [ "$ENABLED" != "true" ]; then
  echo "SKIP: FASTCLAW_SANDBOX_ENABLED=$ENABLED (默认关闭, 与上游 helm 对齐)"
  echo "      启用方法: 编辑 ConfigMap 改 'true' + 在 .env 配 E2B_API_KEY + 重跑 secrets.sh"
  exit 0
fi

TOKEN=$(cat .admin_token 2>/dev/null || true)
[ -n "$TOKEN" ] || { echo "FAIL: .admin_token 不存在. 先 §4.3 创建 admin apikey"; exit 1; }

# macOS 无 gdate 兜底: 用 python3
if command -v gdate >/dev/null 2>&1; then
  T0=$(gdate +%s.%N)
  T1=$(gdate +%s.%N)
else
  T0=$(python3 -c 'import time; print(time.time())')
fi

curl -sN -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"运行 ls / 并告诉我结果"}],"stream":true}' \
     http://localhost:18953/v1/chat/completions > /tmp/sse.log 2>&1 \
  || { echo "FAIL: curl 失败"; cat /tmp/sse.log; exit 1; }

if command -v gdate >/dev/null 2>&1; then
  T1=$(gdate +%s.%N)
else
  T1=$(python3 -c 'import time; print(time.time())')
fi

ELAPSED=$(python3 -c "print(f'{$T1 - $T0:.2f}')")
awk -v e="$ELAPSED" 'BEGIN{ if (e+0 > 3.0) { print "FAIL: sandbox cold "e"s > 3s"; exit 1 } else { print "OK: sandbox cold "e"s (≤ 3s)" } }'
