#!/usr/bin/env bash
# build/build.sh — 克隆上游 fastclaw dev 分支, 构建本地镜像 local:fastclaw:dev
# 用法: bash deploy/local/build/build.sh
# 镜像含 Alpine + fastclaw 二进制, 与上游 Dockerfile runtime stage 同构.

set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/tmp/fastclaw-build}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/fastclaw-ai/fastclaw.git}"
UPSTREAM_REF="${UPSTREAM_REF:-dev}"
IMAGE_TAG="${IMAGE_TAG:-fastclaw:local}"

cd "$(dirname "$0")/.."

# 1. 克隆
if [ ! -d "$BUILD_DIR/.git" ]; then
  echo "==> clone $UPSTREAM_REPO @ $UPSTREAM_REF"
  git clone --depth=1 --branch="$UPSTREAM_REF" "$UPSTREAM_REPO" "$BUILD_DIR"
fi
cd "$BUILD_DIR"

# 2. web UI 构建 + 嵌入
if [ ! -d internal/setup/web ]; then
  echo "==> pnpm install + build (web/)"
  (cd web && pnpm install --frozen-lockfile && pnpm build)
  rm -rf internal/setup/web
  cp -r web/out internal/setup/web
fi

# 3. 同步 bundled skills
echo "==> bundle skills"
for s in skill-creator find-skills; do
  rm -rf "internal/agent/bundled_skills/$s"
  cp -R "skills/$s" "internal/agent/bundled_skills/$s"
done

# 4. go build
echo "==> go build"
# 在 M1 (darwin/arm64) 上交叉编译到 linux/arm64, 匹配 orbstack k8s node
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
  -ldflags "-s -w -X main.version=local -X main.commit=$(git rev-parse --short HEAD) -X main.date=$(date -u +%Y-%m-%dT%H:%M:%SZ) -X github.com/fastclaw-ai/fastclaw/internal/buildinfo.Version=local -X github.com/fastclaw-ai/fastclaw/internal/buildinfo.Commit=$(git rev-parse --short HEAD) -X github.com/fastclaw-ai/fastclaw/internal/buildinfo.Date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -o bin/fastclaw ./cmd/fastclaw

# 5. docker build (orbstack context)
echo "==> docker build -t $IMAGE_TAG"
docker build -f "$(dirname "$0")/Dockerfile" -t "$IMAGE_TAG" "$BUILD_DIR"

echo "==> DONE: $IMAGE_TAG"
ls -lh bin/fastclaw
