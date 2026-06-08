#!/usr/bin/env bash
# image-upgrade.sh IMAGE [NS [DEPLOY | --all]]
#
# 升级 fastclaw 镜像到新 tag, 自动滚动.
#
# 用法:
#   image-upgrade.sh fastclaw:v1.2.3                # 默认 ns fastclaw, 第一个 gateway deploy
#   image-upgrade.sh fastclaw:v1.2.3 fastclaw-acme  # 指定 ns
#   image-upgrade.sh fastclaw:v1.2.3 fastclaw acme  # 指定 ns + deploy
#   image-upgrade.sh fastclaw:v1.2.3 --all          # 全部 gateway 部署
#
# 注: 本地镜像设 imagePullPolicy: Never, 升级前需先 docker build + tag.

set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE [NS [DEPLOY | --all]]}"
NS="${2:-}"
DEPLOY="${3:-}"

do_upgrade() {
  local ns="$1" deploy="$2"
  echo ""
  echo "─── $ns/$deploy: set image -> $IMAGE ───"
  kubectl -n "$ns" set image "deploy/$deploy" "fastclaw=$IMAGE" --record
  kubectl -n "$ns" rollout status "deploy/$deploy" --timeout=180s
  echo "✓ $ns/$deploy 升级完成"
}

if [ "$DEPLOY" = "--all" ] || [ "$NS" = "--all" ]; then
  DEPLOYS=$(kubectl get deploy -A -l app.kubernetes.io/component=gateway \
            -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{end}')
  if [ -z "$DEPLOYS" ]; then
    echo "FAIL: 找不到任何 component=gateway 的 Deployment"; exit 1
  fi
  echo "升级目标:"
  for t in $DEPLOYS; do echo "  $t"; done
  for t in $DEPLOYS; do
    n="${t%/*}"; d="${t#*/}"
    do_upgrade "$n" "$d"
  done
elif [ -z "$NS" ]; then
  # 仅 IMAGE: 默认 fastclaw ns
  NS="fastclaw"
  DEPLOY=$(kubectl -n "$NS" get deploy -l app.kubernetes.io/component=gateway \
           -o jsonpath='{.items[0].metadata.name}')
  [ -n "$DEPLOY" ] || { echo "FAIL: ns $NS 找不到 gateway deployment"; exit 1; }
  do_upgrade "$NS" "$DEPLOY"
elif [ -z "$DEPLOY" ]; then
  # IMAGE NS: 指定 ns, 找该 ns 的 gateway deploy
  DEPLOY=$(kubectl -n "$NS" get deploy -l app.kubernetes.io/component=gateway \
           -o jsonpath='{.items[0].metadata.name}')
  [ -n "$DEPLOY" ] || { echo "FAIL: ns $NS 找不到 gateway deployment"; exit 1; }
  do_upgrade "$NS" "$DEPLOY"
else
  # IMAGE NS DEPLOY: 全指定
  do_upgrade "$NS" "$DEPLOY"
fi

cat <<EOF

✓ 全部升级完毕, 当前镜像: $IMAGE

回滚 (出问题时): deploy/local/ops-scripts/rollback.sh
EOF
