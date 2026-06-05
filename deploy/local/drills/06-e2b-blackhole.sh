#!/usr/bin/env bash
# drills/06-e2b-blackhole.sh
# 故障: 把 Secret 里 E2B_API_KEY 改无效, 模拟 E2B 不可达
# 预期: tool_call 失败, 但非 sandbox 路径 (/api/agents) 仍 200
# 恢复: 编辑 .env 把 E2B_API_KEY 改回真值, 重跑 secrets.sh, rollout restart

set -euo pipefail

cd "$(dirname "$0")/.."

TOKEN=$(cat .admin_token 2>/dev/null || true)
[ -n "$TOKEN" ] || { echo "FAIL: .admin_token 不存在. 先 §4.3 创建 admin apikey"; exit 1; }

# baseline: 非 sandbox 路径应 200
NORMAL=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost:18953/api/agents)
[ "$NORMAL" = "200" ] || { echo "FAIL: baseline 不可用 (HTTP $NORMAL)"; exit 1; }

# patch Secret 改 E2B key 为无效
B64=$(echo -n invalid_e2b_blackhole | base64)
kubectl -n fastclaw patch secret fastclaw-secrets --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/data/E2B_API_KEY\",\"value\":\"$B64\"}]"

# 重启 pod 让 env 生效
kubectl -n fastclaw rollout restart deploy/fastclaw >/dev/null
kubectl -n fastclaw rollout status deploy/fastclaw --timeout=120s
sleep 3

# 复测: 非 sandbox 路径仍 200
STILL=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost:18953/api/agents)
if [ "$STILL" != "200" ]; then
  echo "FAIL: E2B 不可达后 /api/agents 返回 HTTP $STILL"
  exit 1
fi

echo "PASS: E2B 不可达期间, 非 sandbox 路径仍 200"
echo "⚠️  恢复: 编辑 .env 把 E2B_API_KEY 改回真值, 重跑 bash deploy/local/secrets.sh, 然后:"
echo "    kubectl -n fastclaw rollout restart deploy/fastclaw"
