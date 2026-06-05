#!/usr/bin/env bash
# verify/04-multipod-consistency.sh
# 目标: pod-0 写 agent, pod-1 立即可读 (PG 存算分离保证)
# 注意: OPENAI_API_KEY 从调用方 shell env 透传到 pod 内 fastclaw 进程, 由
#       fastclaw 解析后存进 agents.api_key. 不需 cluster 级 secret.

set -euo pipefail

: "${OPENAI_API_KEY:?FAIL: 调用方 shell 需先 export OPENAI_API_KEY=sk-...}"

mapfile -t PODS < <(kubectl -n fastclaw get pod -l app=fastclaw -o name | sort)
[ "${#PODS[@]}" -ge 2 ] || { echo "FAIL: pod 副本 < 2"; exit 1; }

POD0="${PODS[0]}"
POD1="${PODS[1]}"
AGENT_NAME="verify-consistency-$$"

kubectl -n fastclaw exec "$POD0" -- env "OPENAI_API_KEY=$OPENAI_API_KEY" \
  fastclaw agents init "$AGENT_NAME" \
    --provider openai --model gpt-4o-mini --api-key-env OPENAI_API_KEY \
  > /tmp/04-init.log 2>&1 \
  || { echo "FAIL: pod-0 agents init 失败"; cat /tmp/04-init.log; exit 1; }

RESULT=$(kubectl -n fastclaw exec "$POD1" -- fastclaw agents ls | grep "$AGENT_NAME" || true)
[ -n "$RESULT" ] || { echo "FAIL: pod-1 未看到 $AGENT_NAME"; exit 1; }

echo "OK: cross-pod read 一致 ($AGENT_NAME)"
