#!/usr/bin/env bash
# backup.sh [BACKUP_DIR]
#
# 备份所有 fastclaw 命名空间的 PG 库 + minio bucket 到本地目录.
# 默认 BACKUP_DIR=./backups/<timestamp>/
#
# 用法:
#   deploy/local/ops-scripts/backup.sh
#   deploy/local/ops-scripts/backup.sh /tmp/fastclaw-backup-20260608
#
# 输出结构:
#   $BACKUP_DIR/
#     manifest.json                              # 备份元信息 (时间, ns, db, bucket)
#     pg-<ns>-<db>.sql.gz                        # PG 库 dump (gzip)
#     minio-<ns>-<bucket>/                       # bucket 镜像 (目录)

set -euo pipefail

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${1:-./backups/${TS}}"
mkdir -p "$BACKUP_DIR"

# 收集所有 fastclaw ns
NSLIST=$(kubectl get ns -o jsonpath='{range .items[?(@.metadata.labels.app\.kubernetes\.io/part-of=="fastclaw-local")]}{.metadata.name}{" "}{end}')
[ -n "$NSLIST" ] || { echo "FAIL: 无 fastclaw ns"; exit 1; }

# 收集所有 gateway 部署 + 其 ns (找每个 ns 的 db/bucket)
echo "备份目标 ns: $NSLIST"
echo "输出目录: $BACKUP_DIR (绝对路径: $(cd "$BACKUP_DIR" && pwd))"
echo ""

MANIFEST="{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"items\":["
FIRST=true

for NS in $NSLIST; do
  # 找该 ns 的 PG 数据库 (从 secret 的 DSN 解析)
  SECRETS=$(kubectl -n "$NS" get secret -l app.kubernetes.io/component=secrets \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  for SEC in $SECRETS; do
    DSN=$(kubectl -n "$NS" get secret "$SEC" -o jsonpath='{.data.STORAGE_DSN}' 2>/dev/null | base64 -d)
    DB=$(echo "$DSN" | sed -nE 's|.*\/([^?]+)\?.*|\1|p')
    PGHOST=$(echo "$DSN" | sed -nE 's|.*@([^:]+):.*|\1|p')
    [ -n "$DB" ] || continue
    # 找该 ns 的 postgres (共享 or 独立)
    if [ "$PGHOST" = "postgres" ] || [ "$PGHOST" = "localhost" ]; then
      PG_POD="statefulset/postgres"
      PG_NS="fastclaw"  # 共享
    else
      PG_POD="statefulset/postgres"
      PG_NS="$NS"
    fi

    PG_FILE="$BACKUP_DIR/pg-${NS}-${DB}.sql.gz"
    echo "[$NS] PG 备份 $DB -> $(basename "$PG_FILE")"
    kubectl -n "$PG_NS" exec -i "$PG_POD" -- \
      sh -c "pg_dump -U fastclaw -d '$DB' --no-owner --clean" 2>/dev/null \
      | gzip > "$PG_FILE"
    echo "      $(ls -lh "$PG_FILE" | awk '{print $5}')"

    [ "$FIRST" = true ] || MANIFEST+=","
    FIRST=false
    MANIFEST+="{\"ns\":\"$NS\",\"db\":\"$DB\",\"file\":\"pg-${NS}-${DB}.sql.gz\"}"
  done

  # 找该 ns 的 bucket
  CMS=$(kubectl -n "$NS" get cm -l app.kubernetes.io/component=config \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  for CM in $CMS; do
    BUCKET=$(kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.FASTCLAW_OBJECT_STORE_BUCKET}' 2>/dev/null)
    [ -n "$BUCKET" ] || continue
    # 找该 ns 的 minio
    MINIO_NS="$NS"  # 默认假设独立 minio; 共享需手动指定
    if ! kubectl -n "$MINIO_NS" get statefulset minio >/dev/null 2>&1; then
      MINIO_NS="fastclaw"
    fi

    MINIO_DIR="$BACKUP_DIR/minio-${NS}-${BUCKET}"
    echo "[$NS] minio 备份 $BUCKET -> $(basename "$MINIO_DIR")/"
    # minio 容器里无 /backup 目录, 借 /tmp 暂存 tar (pod 退出后清掉, 无副作用)
    # || true 兜底空 bucket 时 mc mirror 退出码非零, 不让 set -e 杀脚本
    kubectl -n "$MINIO_NS" exec -i statefulset/minio -- \
      sh -c "mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null && \
             (mc mirror --quiet --overwrite local/$BUCKET /tmp/$BUCKET || true) && \
             tar czf - -C /tmp $BUCKET" 2>/dev/null > "${MINIO_DIR}.tar.gz" || true
    kubectl -n "$MINIO_NS" exec -i statefulset/minio -- rm -rf /tmp/$BUCKET >/dev/null 2>&1 || true

    [ "$FIRST" = true ] || MANIFEST+=","
    FIRST=false
    MANIFEST+="{\"ns\":\"$NS\",\"bucket\":\"$BUCKET\",\"file\":\"minio-${NS}-${BUCKET}.tar.gz\"}"
  done
done

MANIFEST+="]}"
echo "$MANIFEST" | jq . > "$BACKUP_DIR/manifest.json" 2>/dev/null \
  || echo "$MANIFEST" > "$BACKUP_DIR/manifest.json"

echo ""
echo "✓ 备份完成: $BACKUP_DIR"
ls -la "$BACKUP_DIR"
