#!/usr/bin/env bash
# rollback.sh [NS [DEPLOY | --all]]
#
# 回滚 fastclaw 部署到上一版本. K8s 默认保留最近 10 个 ReplicaSet,
# `rollout undo` 跳到上一个. 想回滚 N 个版本加 --to-revision=N.
#
# 用法:
#   rollback.sh                       # 默认 fastclaw ns
#   rollback.sh fastclaw-acme         # 指定 ns
#   rollback.sh fastclaw acme         # 指定 ns + deploy
#   rollback.sh --all                 # 全部 gateway 部署回滚
#   rollback.sh fastclaw --to-revision=3   # 回滚到第 3 个版本 (用 kubectl rollout history 看 ID)

set -euo pipefail

NS="${1:-}"
DEPLOY="${2:-}"

do_rollback() {
  local ns="$1" deploy="$2"
  echo ""
  echo "─── $ns/$deploy: rollout undo ───"
  kubectl -n "$ns" rollout undo "deploy/$deploy"
  kubectl -n "$ns" rollout status "deploy/$deploy" --timeout=180s
  echo "✓ $ns/$deploy 回滚完成"
}

if [ "$NS" = "--all" ] || [ "$DEPLOY" = "--all" ]; then
  DEPLOYS=$(kubectl get deploy -A -l app.kubernetes.io/component=gateway \
            -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}')
  [ -n "$DEPLOYS" ] || { echo "FAIL: 无 gateway 部署"; exit 1; }
  for t in $DEPLOYS; do
    n="${t%/*}"; d="${t#*/}"
    do_rollback "$n" "$d"
  done
elif [ -z "$NS" ]; then
  NS="fastclaw"
  DEPLOY=$(kubectl -n "$NS" get deploy -l app.kubernetes.io/component=gateway \
           -o jsonpath='{.items[0].metadata.name}')
  [ -n "$DEPLOY" ] || { echo "FAIL: ns $NS 无 gateway 部署"; exit 1; }
  do_rollback "$NS" "$DEPLOY"
elif [ -z "$DEPLOY" ]; then
  DEPLOY=$(kubectl -n "$NS" get deploy -l app.kubernetes.io/component=gateway \
           -o jsonpath='{.items[0].metadata.name}')
  [ -n "$DEPLOY" ] || { echo "FAIL: ns $NS 无 gateway 部署"; exit 1; }
  do_rollback "$NS" "$DEPLOY"
else
  do_rollback "$NS" "$DEPLOY"
fi

cat <<EOF

✓ 回滚完成. 查看历史: kubectl rollout history deploy/<name> -n <ns>
EOF
