# 01 — 新增租户 (New Tenant)

## 场景

同一团队多业务方, 共享 orbstack 集群, 数据面隔离, 控制面共享.
例: 内部 demo 给 `acme` / `globex` / `initech` 三个业务方各开一套, 互不干扰.

## 隔离模型

| 维度 | 共享 | 隔离 |
|---|---|---|
| k8s 节点 | ✓ | - |
| postgres 实例 | ✓ | - |
| minio 实例 | ✓ | - |
| PG 数据库 | - | ✓ `fastclaw_<tenant>` |
| minio bucket | - | ✓ `fastclaw-<tenant>` |
| 命名空间 | - | ✓ `fastclaw-<tenant>` |
| fastclaw 部署 | - | ✓ Deployment + Service + HPA + PDB |
| 凭据 (minio root) | ✓ | - (v1 共享, 见下文) |

**v1 限制**: 共享 minio root 凭据 (`minioadmin`/`minioadmin`). 严格隔离需切到 per-tenant minio user
(IAM policy scoped to 单 bucket), 见 `09-migrate-to-real-cluster.md` 末尾扩展.

## 用法

```bash
deploy/local/ops-scripts/new-tenant.sh acme
```

输出示例:
```
✓ 租户 'acme' 上线
  ns:      fastclaw-acme
  pg db:   fastclaw_acme
  bucket:  fastclaw-acme
  svc:     acme.fastclaw-acme.svc.cluster.local:80
  port:    kubectl -n fastclaw-acme port-forward svc/acme 18953:80
```

租户镜像从本地 `fastclaw:local` 拉, 设 `IMAGE_PULL_POLICY=IfNotPresent` 走远端 registry:
```bash
IMAGE_PULL_POLICY=IfNotPresent deploy/local/ops-scripts/new-tenant.sh acme
```

## 脚本做了什么

1. 创建 namespace `fastclaw-<tenant>`
2. 经共享 postgres pod 跑 `CREATE DATABASE fastclaw_<tenant>`
3. 用 `minio/mc:latest` 一次性 pod 跑 `mc mb fastclaw-<tenant>`
4. 从 `tenant-fastclaw-template.yaml` 渲染 fastclaw 资源 (ConfigMap/Secret/Deployment/Service/HPA/PDB), apply
5. 等 Deployment ready

## 前置

- 默认 fastclaw ns 已部署 (postgres + minio + bucket-init)
- `kubectl` context 指向 orbstack
- `fastclaw:local` 镜像在本地 (`docker images | grep fastclaw:local`)
- 集群 DNS 正常 (跨 ns 访问用 FQDN, 见脚本生成的 DSN)

## 验证

```bash
# 1. pod 跑起来
kubectl -n fastclaw-acme get pods -l app=acme

# 2. 服务可达
kubectl -n fastclaw-acme port-forward svc/acme 18953:80 &
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:18953/readyz   # 200

# 3. PG 库在共享 postgres 里
kubectl -n fastclaw exec -i statefulset/postgres -- \
  psql -U fastclaw -d postgres -c "\l" | grep fastclaw_acme

# 4. bucket 在共享 minio 里
kubectl -n fastclaw exec -i statefulset/minio -- \
  sh -c "mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null && mc ls local/" | grep fastclaw-acme
```

## 资源消耗

每租户 +2 fastclaw pod, 1 HPA/PDB. 注意:
- HPA maxReplicas=4, 多了 K8s 控制面压力大
- 默认 fastclaw HPA 4 cap, 4 个租户 = 16 pod 顶到 host 资源
- 共享 postgres 单实例, 4 租户并发写会撞连接数瓶颈 (默认 100)

## 清理租户

```bash
kubectl delete ns fastclaw-acme
kubectl -n fastclaw exec -i statefulset/postgres -- \
  psql -U fastclaw -d postgres -c "DROP DATABASE fastclaw_acme"
kubectl -n fastclaw exec -i statefulset/minio -- \
  sh -c "mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null && mc rb --force local/fastclaw-acme"
```

## 下一步

- 用户在租户里跑 `fastclaw agents init <name> --provider openai --model gpt-4o-mini --api-key-env OPENAI_API_KEY` (per-agent key 模型)
- 写自动化验收 (类似 `verify/04` 但 cross-tenant)
- 见 [02-new-instance](02-new-instance.md): 需硬隔离 (跨集群, 独立 SLO) 时用
