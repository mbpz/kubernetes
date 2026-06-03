#!/usr/bin/env bash
# secrets.sh — 从 .env 读真实密钥, 创建/更新 fastclaw-secrets
# 用法:
#   cp .env.example .env  &&  $EDITOR .env  &&  bash deploy/local/secrets.sh
#
# 幂等: 重复运行覆盖同名 Secret. 非交互, 失败立即退出.

set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=".env"
[ -f "$ENV_FILE" ] || { echo "FAIL: $ENV_FILE 不存在. 先 cp .env.example .env 并填值."; exit 1; }

# shellcheck disable=SC1090
set -a; . "./$ENV_FILE"; set +a

: "${E2B_API_KEY:?FAIL: E2B_API_KEY 未设置}"
: "${OPENAI_API_KEY:?FAIL: OPENAI_API_KEY 未设置}"

kubectl create namespace fastclaw --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n fastclaw create secret generic fastclaw-secrets \
  --from-literal=STORAGE_DSN="postgres://fastclaw:fastclaw@postgres:5432/fastclaw?sslmode=disable" \
  --from-literal=OBJECT_STORE_ACCESSKEY=minioadmin \
  --from-literal=OBJECT_STORE_SECRETKEY=minioadmin \
  --from-literal=E2B_API_KEY="$E2B_API_KEY" \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "OK: fastclaw-secrets 已同步"
