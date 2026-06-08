#!/usr/bin/env bash
# verify/02-cold-start.sh
# 目标: FastClaw gateway 冷启动 ≤ 5s

set -euo pipefail

# Scale to 0 + 等待所有 pod 消失
kubectl -n fastclaw scale deploy/fastclaw --replicas=0
kubectl -n fastclaw wait --for=delete pod -l app=fastclaw --timeout=60s 2>/dev/null || true

# 计时 scale up + ready. 用 rollout status 而非 wait, 避免 scale 完后
# 短暂无 pod 时 "no matching resources" 竞态.
T0=$(date +%s)
kubectl -n fastclaw scale deploy/fastclaw --replicas=2
kubectl -n fastclaw rollout status deploy/fastclaw --timeout=60s
T1=$(date +%s)

ELAPSED=$((T1 - T0))

if [ "$ELAPSED" -gt 5 ]; then
  echo "FAIL: cold start ${ELAPSED}s > 5s"
  exit 1
fi
echo "OK: cold start ${ELAPSED}s (≤ 5s)"
