# 03 — 镜像升级 (Image Upgrade / Rollout)

## 场景

上游 FastClaw 发版, 拉新代码重新构建, 滚动升级到新版本.

## 用法

### 1. 拉新代码 + 重新构建

```bash
cd /path/to/fastclaw-src
git pull
pnpm install
pnpm build
bundle-skills
GOOS=linux GOARCH=arm64 go build -o bin/fastclaw .
cd /path/to/kubernetes
docker build -t fastclaw:v1.2.3 -f deploy/local/build/Dockerfile /path/to/build-ctx
```

### 2. 升级镜像

```bash
# 默认 fastclaw ns
deploy/local/ops-scripts/image-upgrade.sh fastclaw:v1.2.3

# 跨所有 fastclaw 部署 (默认 ns + 租户 + 实例)
deploy/local/ops-scripts/image-upgrade.sh fastclaw:v1.2.3 --all

# 特定租户
deploy/local/ops-scripts/image-upgrade.sh fastclaw:v1.2.3 fastclaw-acme
```

### 3. 验证

```bash
kubectl -n fastclaw rollout status deploy/fastclaw
deploy/local/verify/all.sh   # 跑全量验收
```

## 脚本做了什么

- `kubectl set image deploy/<name> fastclaw=<IMAGE>` 改字段
- 等 `rollout status` 完成
- `--all` 模式: 跨 ns 找 `app.kubernetes.io/component=gateway` 的所有 Deployment 逐个升

## 镜像 tag 策略

| 环境 | tag 格式 | 例子 |
|---|---|---|
| 本地开发 | `fastclaw:local` | 单 tag, 永远覆盖 |
| CI/预发 | `fastclaw:<commit-sha>` | `fastclaw:a1b2c3d` |
| 生产 | `fastclaw:v<semver>` | `fastclaw:v1.2.3` |

`--all` 模式**慎用**: 多个 ns 共享 tag 时 (默认 + 租户), 一次升级全部.
版本错配会让某个 ns 用新镜像, 另一个还用旧的 — 需确认所有 ns 的副本都准备好新镜像.

## 镜像拉取策略

manifest 里 `imagePullPolicy: Never` (本地 `fastclaw:local` 用).
对远端 registry tag, K8s 默认 `IfNotPresent` (本地有就不拉) — 注意:
- 重新打同名 tag (覆盖式): K8s 不会重新拉, pod 仍跑旧镜像
- **推荐**: 用唯一 tag (sha / semver), K8s 拉新镜像

修改 `imagePullPolicy` 见 `deploy/local/fastclaw-orbstack.yaml`.

## 健康检查

升级期间 (`maxSurge: 1, maxUnavailable: 0`) — 旧 pod 不被 kill, 新 pod 起来后才替换.
期间 `deploy/local/k8s-status.sh` 会有 `Terminating` 状态 pod, 属正常.

## 升级后回滚

```bash
deploy/local/ops-scripts/rollback.sh
# 跳到上一个 ReplicaSet. K8s 默认保留 10 个历史.
```

详见 [04-rollback](04-rollback.md).

## 蓝绿发布 (不用 `--all`)

```bash
# 1. 起绿栈
deploy/local/ops-scripts/new-instance.sh green

# 2. 绿栈验 (手动改 verify 脚本 -n 参数, 或用临时 verify wrapper)
kubectl -n green rollout status deploy/green
kubectl -n green port-forward svc/green 18953:80 &
bash deploy/local/verify/all.sh  # 跑前改 NS

# 3. 切流量: 上游 LB/Ingress 改 service 引用

# 4. 拆蓝栈
kubectl delete ns fastclaw
```

蓝绿不直接用 `image-upgrade.sh --all`, 因为 `--all` 是同名 tag 全升, 不是真正蓝绿.

## 验收

升级后必跑:
```bash
deploy/local/verify/all.sh   # 01-07 全跑, SKIP 也算 PASS
```

如果 03 (RSS) 或 02 (cold start) 退化, 见 [04-rollback](04-rollback.md) 立即回滚.
