#!/usr/bin/env bash
# verify/07-rolling-availability.sh
# 目标: 压测期间 delete 一 pod, 业务 0 非 2xx
# 前置: .admin_token, port-forward svc/fastclaw 18953:80 已启

set -euo pipefail

TOKEN=$(cat .admin_token 2>/dev/null || true)
[ -n "$TOKEN" ] || { echo "FAIL: .admin_token 不存在"; exit 1; }

# 选压测工具
if command -v hey >/dev/null 2>&1; then
  HEY=(hey -n 5000 -c 20)
  PARSE='Status code distribution'
elif command -v wrk >/dev/null 2>&1; then
  HEY=(wrk -t 4 -c 20 -d 10s)
  PARSE='HTTP Codes'
else
  echo "FAIL: 需装 hey 或 wrk (brew install hey)"; exit 1
fi

# 后台压测
"${HEY[@]}" -H "Authorization: Bearer $TOKEN" \
  http://localhost:18953/api/agents > /tmp/07-load.log 2>&1 &
LOAD_PID=$!

sleep 5

# 中途踢一个 pod
VICTIM=$(kubectl -n fastclaw get pod -l app=fastclaw -o name | head -1)
kubectl -n fastclaw delete "$VICTIM" --grace-period=0 --force >/dev/null

wait $LOAD_PID || true

# 解析失败计数
if [[ "${HEY[0]}" == "hey" ]]; then
  # hey 末段形如: [200] 4998  [500] 2
  NON_2XX=$(grep -oE '\[[45][0-9]{2}\] [0-9]+' /tmp/07-load.log | awk '{sum+=$2} END {print sum+0}')
else
  # wrk 末段形如: [200] 4998  [500] 2
  NON_2XX=$(grep -E "\[[45][0-9]{2}\]" /tmp/07-load.log | awk '{sum+=$2} END {print sum+0}')
fi

if [ "${NON_2XX:-0}" -ne 0 ]; then
  echo "FAIL: $NON_2XX 个非 2xx 请求"
  tail -20 /tmp/07-load.log
  exit 1
fi
echo "OK: 0 失败请求 (踢 pod 期间业务不中断)"
