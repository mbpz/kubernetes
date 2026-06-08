#!/usr/bin/env bash
# new-instance.sh INSTANCE
#
# 全独立兄弟栈: 独立 ns + 独立 postgres + 独立 minio + 独立 fastclaw.
# 共享集群控制面, 不共享数据面. 适合 staging / 蓝绿 / 跨区域复制.
#
# 用法:
#   deploy/local/ops-scripts/new-instance.sh staging
#   IMAGE_PULL_POLICY=IfNotPresent deploy/local/ops-scripts/new-instance.sh prod
#
# 删除: kubectl delete ns <NS>; PVC 不会自动回收, 见 02-new-instance.md.

set -euo pipefail

INSTANCE="${1:?usage: $0 INSTANCE}"
[[ "$INSTANCE" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || {
  echo "FAIL: INSTANCE 须 ^[a-z][a-z0-9-]{1,30}\$"; exit 1
}
[[ "$INSTANCE" != "fastclaw" ]] || {
  echo "FAIL: INSTANCE 不能是 fastclaw (默认 ns 名, 避免与已有冲突)"; exit 1
}

NS="${INSTANCE}"  # 实例 ns 不带 fastclaw- 前缀, 避免和租户混
PG_DB="fastclaw_${INSTANCE//-/_}"
BUCKET="fastclaw-${INSTANCE}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-Never}"

# NodePort: 默认 30300, 找 30300-30399 第一个未被占用的; 也可 NODEPORT=xxx 显式指定.
# 租户用 30190-30299, 实例用 30300-30399, 默认 30189 给 fastclaw.
if [ -z "${NODEPORT:-}" ]; then
  USED=$(kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.ports[0].nodePort}{" "}{end}' 2>/dev/null)
  for p in $(seq 30300 30399); do
    if ! echo " $USED " | grep -q " $p "; then
      NODEPORT=$p
      break
    fi
  done
  [ -n "${NODEPORT:-}" ] || { echo "FAIL: 30300-30399 范围 NodePort 已用完"; exit 1; }
fi
[[ "$NODEPORT" =~ ^30[0-9]{3}$ ]] || { echo "FAIL: NODEPORT 须 30000-32767 范围, 实际: $NODEPORT"; exit 1; }

TEMPLATE="$(cd "$(dirname "$0")" && pwd)/instance-template.yaml"
[ -f "$TEMPLATE" ] || { echo "FAIL: 模板不存在: $TEMPLATE"; exit 1; }

# 防呆: 拒绝覆盖默认 ns
[ "$NS" != "fastclaw" ] || { echo "FAIL: 不能用 ns 'fastclaw'"; exit 1; }

echo "[1/2] 应用完整实例栈到 ns $NS"
sed -e "s|__INSTANCE__|$INSTANCE|g" \
    -e "s|__NS__|$NS|g" \
    -e "s|__PG_DB__|$PG_DB|g" \
    -e "s|__BUCKET__|$BUCKET|g" \
    -e "s|__IMAGE_PULL_POLICY__|$IMAGE_PULL_POLICY|g" \
    -e "s|__NODEPORT__|$NODEPORT|g" \
    "$TEMPLATE" | kubectl apply -f -

echo "[2/2] 等 fastclaw + 基础设施就绪"
# 用 rollout status 兜底, 避免 wait 立即 "no matching resources" 竞态.
# STS 没原生 rollout status, 改用 polling 轮询.
for deploy_like in statefulset/postgres statefulset/minio; do
  kubectl -n "$NS" rollout status "$deploy_like" --timeout=180s
done
kubectl -n "$NS" wait --for=condition=complete job/minio-bucket-init --timeout=120s
kubectl -n "$NS" rollout status deploy/"$INSTANCE" --timeout=180s

cat <<EOF

✓ 实例 '$INSTANCE' 上线
  ns:        $NS
  postgres:  postgres.$NS.svc.cluster.local:5432 (独立)
  minio:     minio.$NS.svc.cluster.local:9000 (独立)
  bucket:    $BUCKET
  fastclaw:  $INSTANCE.$NS.svc.cluster.local:80
  nodePort:  $NODEPORT -> 浏览器 http://localhost:$NODEPORT/

资源消耗: 5 pod 起 (postgres+minio+2 fastclaw+1 job), HPA 触发再 +N.
如要 staging/prod 同集群跑, 注意 postgres 单实例无 HA — 重要数据走备份
(见 05-backup-restore.md).
EOF
