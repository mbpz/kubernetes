#!/usr/bin/env bash
# scale.sh NS REPLICAS [--no-hpa]
#
# 手动扩缩容 fastclaw deployment. 同时调 HPA min/max 避免 HPA 自动覆盖.
# 默认: replicas 设为指定值, HPA minReplicas=REPLICAS, maxReplicas=REPLICAS*2 (>= 4)
#
# 用法:
#   deploy/local/ops-scripts/scale.sh fastclaw 3
#   deploy/local/ops-scripts/scale.sh fastclaw 1 --no-hpa    # 改 replicas 不动 HPA
#
# 回退: 跑 verify 02 (cold start) 后用本脚本改回 2

set -euo pipefail

NS="${1:?usage: $0 NS REPLICAS [--no-hpa]}"
REPLICAS="${2:?usage: $0 NS REPLICAS [--no-hpa]}"
NO_HPA=false
[ "${3:-}" = "--no-hpa" ] && NO_HPA=true

[ "$REPLICAS" -ge 1 ] || { echo "FAIL: REPLICAS 须 >= 1"; exit 1; }

DEPLOYS=$(kubectl -n "$NS" get deploy -l app.kubernetes.io/component=gateway \
          -o jsonpath='{.items[*].metadata.name}')
[ -n "$DEPLOYS" ] || { echo "FAIL: ns $NS 无 gateway deployment"; exit 1; }

for d in $DEPLOYS; do
  echo "[$NS/$d] scale --replicas=$REPLICAS"
  kubectl -n "$NS" scale "deploy/$d" --replicas="$REPLICAS"
  if [ "$NO_HPA" = false ]; then
    MAX=$(( REPLICAS * 2 ))
    [ "$MAX" -ge 4 ] || MAX=4
    HPA=$(kubectl -n "$NS" get hpa -l app.kubernetes.io/component=gateway -o jsonpath='{.items[0].metadata.name}')
    if [ -n "$HPA" ]; then
      echo "[$NS/$HPA] set minReplicas=$REPLICAS maxReplicas=$MAX"
      kubectl -n "$NS" patch hpa "$HPA" --type=merge \
        -p "{\"spec\":{\"minReplicas\":$REPLICAS,\"maxReplicas\":$MAX}}"
    fi
  fi
  kubectl -n "$NS" rollout status "deploy/$d" --timeout=180s
done

echo ""
echo "✓ $NS 扩到 $REPLICAS 副本"
echo "  资源消耗 ~$(( REPLICAS * 128 ))Mi mem / $(( REPLICAS / 10 )).$(( (REPLICAS * 100) % 100 / 10 ))CPU req"
echo "  注意: postgres + minio 单实例, >4 fastclaw pod 后瓶颈在 backend"
echo "  验证: deploy/local/k8s-status.sh"
