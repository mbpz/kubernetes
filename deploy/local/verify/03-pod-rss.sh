#!/usr/bin/env bash
# verify/03-pod-rss.sh
# 目标: fastclaw pod RSS 稳态 ≤ 200 MiB

set -euo pipefail

LIMIT_MIB=200
FAIL=0

# kubectl top 需 metrics-server. orbstack 默认带
kubectl -n fastclaw top pod -l app=fastclaw --no-headers | while read -r NAME _ CPU MEM; do
  # MEM 形如 "123Mi", 去后缀
  VALUE=$(echo "$MEM" | sed 's/Mi$//')
  if [ "${VALUE%.*}" -gt "$LIMIT_MIB" ] 2>/dev/null; then
    echo "FAIL: $NAME RSS=$MEM > ${LIMIT_MIB}Mi"
    exit 1
  fi
  echo "OK: $NAME RSS=$MEM (≤ ${LIMIT_MIB}Mi)"
done
