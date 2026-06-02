#!/usr/bin/env bash
# verify/01-binary-size.sh
# 目标: FastClaw 二进制 ≤ 80 MB (近似 OpenClaw 1/40)

set -euo pipefail

POD=$(kubectl -n fastclaw get pod -l app=fastclaw -o name | sed -n 1p)
[ -n "$POD" ] || { echo "FAIL: 无 fastclaw pod"; exit 1; }

SIZE=$(kubectl -n fastclaw exec "$POD" -- sh -c 'wc -c < /usr/local/bin/fastclaw' | tr -d '[:space:]')
LIMIT=$((80 * 1024 * 1024))

if [ "$SIZE" -gt "$LIMIT" ]; then
  echo "FAIL: binary $SIZE bytes > 80MB ($LIMIT)"
  exit 1
fi
echo "OK: binary $SIZE bytes (≤ 80MB)"
