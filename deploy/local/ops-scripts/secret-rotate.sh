#!/usr/bin/env bash
# secret-rotate.sh TYPE
#
# 轮换 fastclaw 集群里的密钥. 三种类型:
#   postgres  改 PG 密码 + 同步更新所有 fastclaw-* Secret 的 STORAGE_DSN
#   minio     改 minio root 凭据 + 同步更新所有 fastclaw-* Secret 的 ACCESSKEY/SECRETKEY
#   e2b       改 E2B_API_KEY (E2B_API_KEY Secret key, 启用 sandbox 时才存在)
#
# 用法:
#   deploy/local/ops-scripts/secret-rotate.sh postgres
#   deploy/local/ops-scripts/secret-rotate.sh minio
#   deploy/local/ops-scripts/secret-rotate.sh e2b
#
# 强烈建议: 改前先 backup (deploy/local/ops-scripts/backup.sh).

set -euo pipefail

TYPE="${1:?usage: $0 TYPE  (postgres|minio|e2b)}"

# 收集所有 fastclaw ns
NSLIST=$(kubectl get ns -o jsonpath='{range .items[?(@.metadata.labels.app\.kubernetes\.io/part-of=="fastclaw-local")]}{.metadata.name}{" "}{end}')
[ -n "$NSLIST" ] || { echo "FAIL: 无 fastclaw ns"; exit 1; }

rotate_postgres() {
  echo "─── postgres 密码轮换 ───"
  # 1. 提示输入新密码 (或读 stdin)
  read -r -s -p "新 postgres 密码 (输入隐藏): " NEW_PWD
  echo ""
  [ -n "$NEW_PWD" ] || { echo "FAIL: 密码空"; exit 1; }

  # 2. 改 PG 内部用户密码
  for ns in $NSLIST; do
    if kubectl -n "$ns" get statefulset postgres >/dev/null 2>&1; then
      echo "[$ns] ALTER USER fastclaw"
      kubectl -n "$ns" exec -i statefulset/postgres -- \
        psql -U fastclaw -d postgres -c "ALTER USER fastclaw WITH PASSWORD '$NEW_PWD'"
    fi
  done

  # 3. 更新所有 fastclaw Secret 的 DSN
  for ns in $NSLIST; do
    for sec in $(kubectl -n "$ns" get secret -l app.kubernetes.io/component=secrets -o jsonpath='{.items[*].metadata.name}'); do
      OLD_DSN=$(kubectl -n "$ns" get secret "$sec" -o jsonpath='{.data.STORAGE_DSN}' | base64 -d)
      NEW_DSN=$(echo "$OLD_DSN" | sed -E "s|(://[^:]+:)[^@]+(@)|\1${NEW_PWD}\2|")
      kubectl -n "$ns" patch secret "$sec" -p "{\"stringData\":{\"STORAGE_DSN\":\"$NEW_DSN\"}}"
      echo "[$ns] secret $sec STORAGE_DSN 已更新"
    done
  done

  # 4. 滚动 fastclaw
  for ns in $NSLIST; do
    for d in $(kubectl -n "$ns" get deploy -l app.kubernetes.io/component=gateway -o jsonpath='{.items[*].metadata.name}'); do
      echo "[$ns/$d] rollout restart"
      kubectl -n "$ns" rollout restart "deploy/$d"
    done
  done
}

rotate_minio() {
  echo "─── minio root 凭据轮换 ───"
  read -r -p "新 MINIO_ROOT_USER (默认 minioadmin): " NEW_USER
  NEW_USER="${NEW_USER:-minioadmin}"
  read -r -s -p "新 MINIO_ROOT_PASSWORD (输入隐藏): " NEW_PWD
  echo ""
  [ -n "$NEW_PWD" ] || { echo "FAIL: 密码空"; exit 1; }

  for ns in $NSLIST; do
    if kubectl -n "$ns" get statefulset minio >/dev/null 2>&1; then
      echo "[$ns] 更新 minio STS env"
      kubectl -n "$ns" set env statefulset/minio \
        MINIO_ROOT_USER="$NEW_USER" MINIO_ROOT_PASSWORD="$NEW_PWD"
      kubectl -n "$ns" rollout status statefulset/minio --timeout=180s
    fi
  done

  for ns in $NSLIST; do
    for sec in $(kubectl -n "$ns" get secret -l app.kubernetes.io/component=secrets -o jsonpath='{.items[*].metadata.name}'); do
      kubectl -n "$ns" patch secret "$sec" -p "{\"stringData\":{
        \"OBJECT_STORE_ACCESSKEY\":\"$NEW_USER\",
        \"OBJECT_STORE_SECRETKEY\":\"$NEW_PWD\"
      }}"
      echo "[$ns] secret $sec ACCESSKEY/SECRETKEY 已更新"
    done
  done

  for ns in $NSLIST; do
    for d in $(kubectl -n "$ns" get deploy -l app.kubernetes.io/component=gateway -o jsonpath='{.items[*].metadata.name}'); do
      echo "[$ns/$d] rollout restart"
      kubectl -n "$ns" rollout restart "deploy/$d"
    done
  done
}

rotate_e2b() {
  echo "─── E2B_API_KEY 轮换 ───"
  read -r -s -p "新 E2B_API_KEY: " NEW_KEY
  echo ""
  [ -n "$NEW_KEY" ] || { echo "FAIL: key 空"; exit 1; }

  # E2B key 仅在启用 sandbox 时注入 Secret, 由 secrets.sh 从 .env 读.
  # 各 fastclaw Secret 里有 E2B_API_KEY 键 (若有).
  for ns in $NSLIST; do
    for sec in $(kubectl -n "$ns" get secret -l app.kubernetes.io/component=secrets -o jsonpath='{.items[*].metadata.name}'); do
      if kubectl -n "$ns" get secret "$sec" -o jsonpath='{.data.E2B_API_KEY}' >/dev/null 2>&1; then
        kubectl -n "$ns" patch secret "$sec" -p "{\"stringData\":{\"E2B_API_KEY\":\"$NEW_KEY\"}}"
        echo "[$ns] secret $sec E2B_API_KEY 已更新 (无需重启, 下次 sandbox 调用生效)"
      fi
    done
  done
}

case "$TYPE" in
  postgres) rotate_postgres ;;
  minio)    rotate_minio ;;
  e2b)      rotate_e2b ;;
  *) echo "FAIL: TYPE 须 postgres|minio|e2b"; exit 1 ;;
esac

echo ""
echo "✓ $TYPE 轮换完成"
echo "  验证: deploy/local/verify/all.sh"
