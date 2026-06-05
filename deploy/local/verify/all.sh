#!/usr/bin/env bash
# verify/all.sh — 顺序跑 01..07, 短路
# 用法: bash deploy/local/verify/all.sh

set -euo pipefail

cd "$(dirname "$0")"

for s in 0*.sh; do
  echo "─── running $s ───"
  bash "$s"
done
echo "ALL VERIFY PASS"
