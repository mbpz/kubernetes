#!/usr/bin/env bash
# restore.sh BACKUP_DIR [TARGET_NS]
#
# 从 backup.sh 输出恢复. 默认按 manifest.json 的 ns 恢复, 也可指定目标 ns
# (用于把 fastclaw 备份恢复到 staging 之类的副本).
#
# 用法:
#   deploy/local/ops-scripts/restore.sh /tmp/test-backup4
#   deploy/local/ops-scripts/restore.sh ./backups/20260608-135643 fastclaw-stage
#
# ⚠️  覆盖式恢复: 目标 db/bucket 现有数据会被覆盖 (PG 用 --clean, minio 用 --overwrite).
# 恢复前建议再 backup 一次, 避免覆盖错.

set -euo pipefail

BACKUP_DIR="${1:?usage: $0 BACKUP_DIR [TARGET_NS]}"
TARGET_NS="${2:-}"  # 空 = 用 manifest 里的 ns

[ -f "$BACKUP_DIR/manifest.json" ] || { echo "FAIL: $BACKUP_DIR/manifest.json 不存在"; exit 1; }

ITEMS=$(jq -c '.items[]' "$BACKUP_DIR/manifest.json")
echo "恢复源: $BACKUP_DIR"
[ -n "$TARGET_NS" ] && echo "目标 ns 重写: $TARGET_NS"
echo ""

echo "⚠️  警告: 即将覆盖目标 db/bucket. 10s 后开始 (Ctrl-C 取消)"
sleep 10

for item in $ITEMS; do
  NS=$(echo "$item" | jq -r '.ns')
  FILE=$(echo "$item" | jq -r '.file')
  [ -n "$TARGET_NS" ] && NS="$TARGET_NS"

  if [[ "$FILE" == pg-*.sql.gz ]]; then
    DB=$(echo "$item" | jq -r '.db')
    # 找该 ns 的 PG
    if [[ "$NS" == "fastclaw" ]] || kubectl -n fastclaw get cm -l app.kubernetes.io/component=config -o name >/dev/null 2>&1; then
      PG_NS="fastclaw"
    else
      PG_NS="$NS"
    fi
    # 取 postgres host
    PGHOST=$(kubectl -n "$NS" get secret -l app.kubernetes.io/component=secrets -o jsonpath='{.items[0].data.STORAGE_DSN}' 2>/dev/null | base64 -d | sed -nE 's|.*@([^:]+):.*|\1|p')
    if [ "$PGHOST" != "postgres" ]; then
      # 跨 ns PG: 改 DSN 用 FQDN
      # 直接 exec 进 ns 的 postgres (假设有)
      PG_NS="$NS"
    fi

    echo "[$NS] 恢复 PG $DB <- $(basename "$FILE")"
    gunzip -c "$BACKUP_DIR/$FILE" | kubectl -n "$PG_NS" exec -i statefulset/postgres -- \
      psql -U fastclaw -d "$DB" -v ON_ERROR_STOP=1 2>&1 | tail -5
  elif [[ "$FILE" == minio-*.tar.gz ]]; then
    BUCKET=$(echo "$item" | jq -r '.bucket')
    MINIO_NS="$NS"
    if ! kubectl -n "$MINIO_NS" get statefulset minio >/dev/null 2>&1; then
      MINIO_NS="fastclaw"
    fi
    echo "[$NS] 恢复 minio $BUCKET <- $(basename "$FILE")"
    # tar 解到 minio 容器 /tmp, 再 mc mirror 回 bucket (覆盖)
    kubectl -n "$MINIO_NS" exec -i statefulset/minio -- \
      sh -c "rm -rf /tmp/$BUCKET && tar xzf - -C /tmp" < "$BACKUP_DIR/$FILE" >/dev/null
    kubectl -n "$MINIO_NS" exec -i statefulset/minio -- \
      sh -c "mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null && \
             mc mirror --quiet --overwrite --remove /tmp/$BUCKET local/$BUCKET" >/dev/null
    kubectl -n "$MINIO_NS" exec -i statefulset/minio -- rm -rf /tmp/$BUCKET >/dev/null
  fi
done

echo ""
echo "✓ 恢复完成"
echo "  - fastclaw pod 可能需要重启以 reload 内存里的 agent/session 缓存"
echo "  - 验证: deploy/local/verify/all.sh"
