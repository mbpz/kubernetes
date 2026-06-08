#!/usr/bin/env bash
# verify/03-pod-rss.sh
# 目标: fastclaw pod RSS 稳态 ≤ 200 MiB

set -euo pipefail

LIMIT_MIB=200
FAIL=0

# kubectl top 输出 3 列: NAME CPU MEM. MEM 形如 "123Mi"
kubectl -n fastclaw top pod -l app=fastclaw --no-headers | while read -r NAME CPU MEM; do
  VALUE=$(echo "$MEM" | sed 's/Mi$//')
  if [ "${VALUE:-0%.*}" -gt "$LIMIT_MIB" ] 2>/dev/null; then
    echo "FAIL: $NAME RSS=$MEM > ${LIMIT_MIB}Mi"
    exit 1
  fi
  echo "OK: $NAME RSS=$MEM (≤ ${LIMIT_MIB}Mi)"
done
