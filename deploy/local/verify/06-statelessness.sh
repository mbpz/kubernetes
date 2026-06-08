#!/usr/bin/env bash
# verify/06-statelessness.sh
# 目标: fastclaw pod 全部 kill + 重启后, PG 数据完整 (agent 仍可读)
# 前置: 04-multipod-consistency.sh 已跑过, 创了 verify-consistency-* agent
#       没 04 的 agent 走 SKIP — 06 验的是 PG 持久, 需先有数据可验.

set -euo pipefail

# 找 04 创建的 agent 名称 (verify-consistency-<pid>)
AGENT_NAME=$(kubectl -n fastclaw exec deploy/fastclaw -- fastclaw agents ls \
  | awk '/verify-consistency-/ {print $1; exit}')
if [ -z "$AGENT_NAME" ]; then
  echo "SKIP: 未找到 04 创建的 agent. 集群侧无数据可验持久化"
  echo "      启用方法: 配 OPENAI_API_KEY 后先跑 04, 再跑本脚本"
  exit 0
fi

# 强制 delete 所有 fastclaw pod, 触发 emptyDir 清空 + K8s 重拉
kubectl -n fastclaw delete pod -l app=fastclaw --grace-period=0 --force >/dev/null
kubectl -n fastclaw wait --for=condition=ready pod -l app=fastclaw --timeout=60s \
  || { echo "FAIL: pod 重启后未就绪"; exit 1; }

# PG 数据应完整: agent 仍存在
RESULT=$(kubectl -n fastclaw exec deploy/fastclaw -- fastclaw agents ls | grep "$AGENT_NAME" || true)
[ -n "$RESULT" ] || { echo "FAIL: 重启后 $AGENT_NAME 丢失 (PG 数据未持久?)"; exit 1; }

echo "OK: 重启后状态完整 ($AGENT_NAME 仍在)"
