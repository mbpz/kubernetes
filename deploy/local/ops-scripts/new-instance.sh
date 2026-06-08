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
  port:      kubectl -n $NS port-forward svc/$INSTANCE 18953:80

资源消耗: 5 pod 起 (postgres+minio+2 fastclaw+1 job), HPA 触发再 +N.
如要 staging/prod 同集群跑, 注意 postgres 单实例无 HA — 重要数据走备份
(见 05-backup-restore.md).
EOF
