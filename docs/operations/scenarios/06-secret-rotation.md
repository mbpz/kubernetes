# 06 — 密钥轮换 (Secret Rotation)

## 场景

- **周期性**: 90/180 天强制轮换
- **离职**: 某员工持有 E2B key, 走人后立即作废
- **泄露**: 凭据进 git log / Slack / 截图
- **合规**: SOC2 / ISO27001 要求

## 三类凭据

| 类型 | 在哪 | 轮换影响 |
|---|---|---|
| postgres 密码 | `statefulset/postgres` + 所有 `Secret.STORAGE_DSN` | 改 PG 内部用户 + 更新所有 DSN + 滚动 fastclaw |
| minio root 凭据 | `statefulset/minio` env + 所有 `Secret.OBJECT_STORE_{ACCESS,SECRET}KEY` | 改 STS env + 滚动 minio + 更新所有 Secret + 滚动 fastclaw |
| E2B_API_KEY | 仅启用 sandbox 时的 `Secret.E2B_API_KEY` | 改 Secret 即可, fastclaw 运行时读 |

## 用法

### postgres

```bash
deploy/local/ops-scripts/secret-rotate.sh postgres
# 提示输入新密码, 隐藏输入
```

脚本:
1. 跨所有 ns 的 postgres STS, `ALTER USER fastclaw WITH PASSWORD ...`
2. 跨所有 fastclaw Secret, sed 替换 DSN 里的密码段
3. 跨所有 fastclaw Deployment, `rollout restart`

### minio

```bash
deploy/local/ops-scripts/secret-rotate.sh minio
# 提示输入新 user + password
```

脚本:
1. 跨所有 ns 的 minio STS, `set env MINIO_ROOT_USER/PASSWORD`
2. `rollout status statefulset/minio` 等新 pod 起来
3. 跨所有 fastclaw Secret, 改 ACCESSKEY/SECRETKEY
4. 跨所有 fastclaw Deployment, `rollout restart`

⚠️ **minio 凭据轮换期间, bucket-init Job (一次性) 不受影响** (Job 跑时凭据已固定, 不读 Secret).
**新加租户** 用 new-tenant.sh 会用新凭据.

### e2b

```bash
deploy/local/ops-scripts/secret-rotate.sh e2b
# 提示输入新 E2B key
```

脚本:
1. 跨所有 fastclaw Secret, 改 E2B_API_KEY 键
2. 不滚动 fastclaw (运行时读, 下次 sandbox 调用生效)

## 轮换前必做

```bash
# 1. 备份 (出问题可恢复)
deploy/local/ops-scripts/backup.sh

# 2. 通知: 轮换期间 fastclaw 滚动 1-2 次, 短时不可用
```

## 轮换后验证

```bash
# 1. fastclaw pod 起得来
kubectl -n fastclaw get pods -l app=fastclaw
# 2. /readyz 通
kubectl -n fastclaw port-forward svc/fastclaw 18953:80 &
curl http://localhost:18953/readyz
# 3. 业务流
deploy/local/verify/04-multipod-consistency.sh   # 需 OPENAI_API_KEY
```

## 租户场景

脚本自动跨所有 fastclaw ns 操作, 包含租户/实例. 无需单独跑.

## 限制 & 风险

| 风险 | 缓解 |
|---|---|
| postgres 改密码瞬间, fastclaw 还在用旧 DSN 拉, 报 "password auth failed" | rollout restart 前几秒的 503 属正常; 客户端 retry |
| minio STS 滚动期间 bucket 不可用, 备份/agent 文件读写失败 | 选低峰期; 或先停 fastclaw 再轮 minio |
| E2B key 输错, sandbox 全部 401 | 改回旧 key (secrets.sh 从 .env 重注入) |
| `kubectl set env` 在 STS 上触发滚动, 但 `partition` 字段被忽略 | orbstack 单节点无 partition 风险, prod 多节点要注意 rolling 策略 |

## 自动轮换 (进阶)

生产环境一般用 Vault / External Secrets Operator 配 AWS Secrets Manager / GCP Secret Manager.
本仓库 v1 直接 kubectl patch, 见 [09-migrate-to-real-cluster](09-migrate-to-real-cluster.md) 末尾.

## 应急: 凭据泄露但脚本跑不了

```bash
# 直接改 Secret (绕过脚本)
kubectl -n fastclaw edit secret fastclaw-secrets
# base64 编码后填入, kubectl apply 触发 fastclaw 重读 env (需滚动)

# 强制滚动
kubectl -n fastclaw rollout restart deploy/fastclaw
```

PG / minio 的"根"密码绕不开脚本, 必须 ALTER USER / set env.
