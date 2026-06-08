# 运维操作手册 (Operations Runbook)

本地 orbstack 集群 (`fastclaw` 命名空间) + 多租户/多实例扩展场景的操作手册.
所有脚本在 `deploy/local/ops-scripts/`, 命名以场景对齐.

## 拓扑模型

```
┌──────────────────────────────────────────────────────┐
│  orbstack k8s (单节点)                                │
│                                                       │
│  ┌─ infra (kube-system) ──────────────────────────┐  │
│  │  metrics-server, dns, etcd                      │  │
│  └────────────────────────────────────────────────┘  │
│                                                       │
│  ┌─ ns: fastclaw (default tenant) ─────────────────┐  │
│  │  postgres  ─┐                                    │  │
│  │  minio     ─┤ shared infra (单实例)              │  │
│  │  bucket-init│                                    │  │
│  │  fastclaw deploy (2 pod, HPA 2-4)               │  │
│  │  ConfigMap / Secret / HPA / PDB                 │  │
│  └────────────────────────────────────────────────┘  │
│                                                       │
│  ┌─ ns: fastclaw-acme (新租户) ─────────────────────┐  │
│  │  fastclaw-acme deploy ─┐                         │  │
│  │  ConfigMap / Secret    │ 共享 postgres+minio     │  │
│  │                        │ 独立 DB+bucket          │  │
│  └────────────────────────┘                         │  │
│                                                       │
│  ┌─ ns: fastclaw-stage (兄弟实例, 全独立) ──────────┐  │
│  │  postgres-stage ─┐                                │  │
│  │  minio-stage    ─┤ 独立栈                        │  │
│  │  fastclaw-stage deploy                          │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

## 场景索引

| 场景 | 文档 | 脚本 | 何时用 |
|---|---|---|---|
| 新增租户 | [01-new-tenant](scenarios/01-new-tenant.md) | `new-tenant.sh` | 共享集群加新业务方, 软隔离 |
| 新增实例 | [02-new-instance](scenarios/02-new-instance.md) | `new-instance.sh` | staging / 蓝绿 / 跨区域, 硬隔离 |
| 镜像升级 | [03-image-upgrade](scenarios/03-image-upgrade.md) | `image-upgrade.sh` | 上游新版本, 滚动发布 |
| 回滚 | [04-rollback](scenarios/04-rollback.md) | `rollback.sh` | 升级后出问题, 1 步回退 |
| 备份恢复 | [05-backup-restore](scenarios/05-backup-restore.md) | `backup.sh` / `restore.sh` | 灾难前快照 / 误删恢复 |
| 密钥轮换 | [06-secret-rotation](scenarios/06-secret-rotation.md) | `secret-rotate.sh` | 周期性 / 离职 / 泄露 |
| 扩缩容 | [07-scaling](scenarios/07-scaling.md) | `scale.sh` | 流量高峰 / 节约成本 |
| 灾难恢复 | [08-disaster-recovery](scenarios/08-disaster-recovery.md) | (runbook) | 集群全毁, 从备份重建 |
| 迁生产 | [09-migrate-to-real-cluster](scenarios/09-migrate-to-real-cluster.md) | (runbook) | orbstack -> EKS/GKE/AKS |

## 通用约定

- **命名空间** = `fastclaw` (默认) / `fastclaw-<tenant>` (新租户) / `<name>` (兄弟实例)
- **PG 数据库** = `fastclaw` (默认) / `fastclaw_<tenant>` (新租户, 下划线) / `<name>` (兄弟)
- **MinIO bucket** = `fastclaw` (默认) / `fastclaw-<tenant>` (新租户, 连字符)
- **Secret** = `fastclaw-secrets` (默认) / `fastclaw-<tenant>-secrets` (新租户) / 独立 (兄弟)
- **标签** 全部沿用 `app.kubernetes.io/{part-of,component,name,managed-by}` 方案 (见 `deploy/local/fastclaw-orbstack.yaml` 头部)
- **资源配额** (request/limit) 维持 manifest 默认, 改 `fastclaw-config` ConfigMap

## 前提

- 集群 `kubectl` context 指向 orbstack (`docker context orbstack` 或 KUBECONFIG)
- `psql` 客户端 (备份用)
- `mc` (MinIO client, 备份用; 镜像已含 `minio/mc:latest` 可在 pod 里跑)
- `jq` (部分脚本)
- 镜像在本地: `fastclaw:local` (构建见 `deploy/local/build/build.sh`)

## 速查

```bash
# 看一眼所有资源按 component 分组
deploy/local/k8s-status.sh

# 跑全量验收
deploy/local/verify/all.sh

# 备份所有租户 (PG 全库 + 所有 bucket)
deploy/local/ops-scripts/backup.sh

# 新增租户
deploy/local/ops-scripts/new-tenant.sh acme

# 升级 fastclaw 到新 tag
deploy/local/ops-scripts/image-upgrade.sh v1.2.3

# 出问题回滚
deploy/local/ops-scripts/rollback.sh fastclaw
```
