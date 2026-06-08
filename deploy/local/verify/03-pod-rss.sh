#!/usr/bin/env bash
# verify/03-pod-rss.sh
# 目标: fastclaw pod RSS 稳态 ≤ 200 MiB

set -euo pipefail

LIMIT_MIB=200

# metrics-server 刚拉起或 pod 刚就绪时, metrics 可能未抓取 (--metric-resolution=15s).
# 短轮询等到有数据, 避免 02 cold-start 跑完立刻 03 时的竞态.
# 02 结束到 03 开始可能跨多个 scrape 周期, 给 60s 兜底.
for _ in $(seq 1 30); do
  if kubectl -n fastclaw top pod -l app=fastclaw --no-headers 2>/dev/null | grep -q .; then
    break
  fi
  sleep 2
done

kubectl -n fastclaw top pod -l app=fastclaw --no-headers | while read -r NAME CPU MEM; do
  VALUE=$(echo "$MEM" | sed 's/Mi$//')
  if [ "${VALUE:-0%.*}" -gt "$LIMIT_MIB" ] 2>/dev/null; then
    echo "FAIL: $NAME RSS=$MEM > ${LIMIT_MIB}Mi"
    exit 1
  fi
  echo "OK: $NAME RSS=$MEM (≤ ${LIMIT_MIB}Mi)"
done
