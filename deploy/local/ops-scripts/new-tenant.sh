#!/usr/bin/env bash
# new-tenant.sh TENANT
#
# 多租户软隔离: 共享 fastclaw ns 的 postgres+minio, 独立 DB / bucket / ns / deploy.
# 共享集群控制面, 数据面按 tenant 隔离. 适合同一团队多业务方.
#
# 用法:
#   deploy/local/ops-scripts/new-tenant.sh acme
#   IMAGE_PULL_POLICY=IfNotPresent deploy/local/ops-scripts/new-tenant.sh acme
#
# 删除: kubectl delete ns fastclaw-<tenant>  (PG DB + bucket 需手动清, 见 01-new-tenant.md)

set -euo pipefail

TENANT="${1:?usage: $0 TENANT}"
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || {
  echo "FAIL: TENANT 须 ^[a-z][a-z0-9-]{1,30}\$ (小写字母打头, 字母数字+连字符, ≤ 31 字符)"; exit 1
}

NS="fastclaw-${TENANT}"
PG_DB="fastclaw_${TENANT//-/_}"   # PG 不允许连字符
BUCKET="fastclaw-${TENANT}"      # bucket 允许连字符
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-Never}"  # 本地 fastclaw:local
INFRA_NS="${INFRA_NS:-fastclaw}"  # 共享 infra 所在的 ns

# NodePort: 默认 30190, 找 30190-30299 第一个未被占用的; 也可 NODEPORT=xxx 显式指定.
if [ -z "${NODEPORT:-}" ]; then
  USED=$(kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.ports[0].nodePort}{" "}{end}' 2>/dev/null)
  for p in $(seq 30190 30299); do
    if ! echo " $USED " | grep -q " $p "; then
      NODEPORT=$p
      break
    fi
  done
  [ -n "${NODEPORT:-}" ] || { echo "FAIL: 30190-30299 范围 NodePort 已用完"; exit 1; }
fi
[[ "$NODEPORT" =~ ^30[0-9]{3}$ ]] || { echo "FAIL: NODEPORT 须 30000-32767 范围, 实际: $NODEPORT"; exit 1; }

TEMPLATE="$(cd "$(dirname "$0")" && pwd)/tenant-fastclaw-template.yaml"
[ -f "$TEMPLATE" ] || { echo "FAIL: 模板不存在: $TEMPLATE"; exit 1; }

# 共享 infra 必须在
kubectl -n "$INFRA_NS" get statefulset postgres >/dev/null 2>&1 || {
  echo "FAIL: 共享 postgres 不在 ns '$INFRA_NS'. 先部署基础设施."; exit 1
}
kubectl -n "$INFRA_NS" get statefulset minio >/dev/null 2>&1 || {
  echo "FAIL: 共享 minio 不在 ns '$INFRA_NS'. 先部署基础设施."; exit 1
}

# 1. 命名空间
echo "[1/5] 创建 namespace $NS"
kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f -

# 2. PG 数据库 (经 postgres pod 跑 psql)
echo "[2/5] 创建 PG 数据库 $PG_DB"
kubectl -n "$INFRA_NS" exec -i statefulset/postgres -- \
  psql -U fastclaw -d postgres -c "CREATE DATABASE \"$PG_DB\"" 2>&1 \
  | grep -vE "already exists|ERROR.*duplicate" \
  || echo "      (已存在, 跳过)"

# 3. MinIO bucket
echo "[3/5] 创建 minio bucket $BUCKET"
# 用 --command 覆写镜像 ENTRYPOINT (默认是 mc, 没法直接 sh -c). 跑完 --rm 自动清.
kubectl -n "$INFRA_NS" run mc-client --rm -i --restart=Never --image=minio/mc:latest \
  --command -- sh -c "mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null && \
                       mc mb --ignore-existing local/$BUCKET && \
                       mc ls local/" 2>&1 | tail -5

# 4. 渲染并 apply 租户 fastclaw 资源
echo "[4/5] 应用 fastclaw 租户资源 (config/secret/deploy/svc/hpa/pdb)"
sed -e "s|__NS__|$NS|g" \
    -e "s|__TENANT__|$TENANT|g" \
    -e "s|__INFRA_NS__|$INFRA_NS|g" \
    -e "s|__PG_DB__|$PG_DB|g" \
    -e "s|__BUCKET__|$BUCKET|g" \
    -e "s|__IMAGE_PULL_POLICY__|$IMAGE_PULL_POLICY|g" \
    -e "s|__NODEPORT__|$NODEPORT|g" \
    "$TEMPLATE" | kubectl apply -f -

# 5. 等就绪
echo "[5/5] 等 pod ready"
kubectl -n "$NS" rollout status deploy/"$TENANT" --timeout=120s

cat <<EOF

✓ 租户 '$TENANT' 上线
  ns:        $NS
  pg db:     $PG_DB (在共享 postgres 里)
  bucket:    $BUCKET (在共享 minio 里)
  svc:       $TENANT.$NS.svc.cluster.local:80
  nodePort:  $NODEPORT -> 浏览器 http://localhost:$NODEPORT/

下一步: 在租户里跑 fastclaw agents init (per-agent key 模型, 见 docs/operations/README.md)
EOF
