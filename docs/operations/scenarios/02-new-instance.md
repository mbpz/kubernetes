# 02 — 新增实例 (New Instance / Sibling Stack)

## 场景

与默认 fastclaw 栈**完全独立**的兄弟栈: 独立 postgres, 独立 minio, 独立 fastclaw.
控制面共享 (k8s 节点/etcd), 数据面不共享.

适用:
- **staging / 预发**: 独立基础设施, 不污染默认栈
- **蓝绿发布**: 绿栈上线, 验证 OK 后切流量, 蓝栈下线
- **跨区域复制**: 同集群内多实例 (e.g. 模拟 region A / B), 验证跨区延迟

不适用:
- 多业务方 (用 [01-new-tenant](01-new-tenant.md), 资源共享成本低)

## 与 new-tenant 的对比

| 维度 | new-tenant | new-instance |
|---|---|---|
| 命名空间 | `fastclaw-<tenant>` | `<instance>` (无前缀) |
| postgres | 共享默认栈 | 独立 |
| minio | 共享默认栈 | 独立 |
| bucket 命名 | `fastclaw-<tenant>` | `fastclaw-<instance>` |
| 资源成本 | +2 pod (仅 fastclaw) | +5+ pod (pg+minio+job+2 fastclaw) |
| 隔离级别 | 数据面软隔离 (DB/bucket) | 数据面硬隔离 (物理独立) |
| 适用 | 多业务方, 资源敏感 | 多环境, 故障域隔离 |

## 用法

```bash
deploy/local/ops-scripts/new-instance.sh staging
```

可选环境变量:
- `IMAGE_PULL_POLICY=IfNotPresent` (远端 registry)
- 自定义 HPA/资源/镜像 tag: 模板在 `deploy/local/ops-scripts/instance-template.yaml`, sed 改完再 apply

## 脚本做了什么

1. apply 完整模板: namespace + ConfigMap + Secret + postgres STS + minio STS + bucket-init Job + fastclaw Deployment + Service + HPA + PDB
2. 等 postgres / minio pod ready
3. 等 bucket-init job complete (创建独立 bucket)
4. 等 fastclaw rollout 完成

## 前置

- 集群有足够资源: 每实例 +5 pod (pg+minio+job+2 fastclaw), ~1.5GB mem
- 镜像 (本地 `fastclaw:local` 或远端)
- `kubectl` context 正确

## 验证

```bash
# 全栈检查
deploy/local/k8s-status.sh   # 默认 ns
kubectl -n staging get pods
# NodePort 自动分配 (30300 范围), 看脚本输出:  http://localhost:<nodePort>/
curl -sS http://localhost:30300/readyz   # 200 (假设分配到 30300)

# 独立 PG 库 (与默认 fastclaw 库不共享)
kubectl -n staging exec -i statefulset/postgres -- \
  psql -U fastclaw -d postgres -c "\l" | grep fastclaw_

# 独立 bucket
kubectl -n staging exec -i statefulset/minio -- \
  sh -c "mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null && mc ls local/"
```

## 资源 & SLO 提示

- 2 实例 + 默认栈 = 11+ pod, M1 16G 可能 OOM
- HPA 各自独立 (实例间不互相关联), 共享 minio/postgres 不会成为瓶颈 (各自独立)
- **没有跨实例流量切换**: K8s 内部 DNS 用 `<svc>.<ns>.svc.cluster.local`, 切流量需手动改上游

## 清理

```bash
kubectl delete ns staging

# PVC 不会自动回收 (StatefulSet 设计), 检查并删:
kubectl get pvc -A | grep staging
kubectl delete pvc -n staging <name> ...
```

## 蓝绿发布示例

```bash
# 1. 起绿栈
IMAGE_PULL_POLICY=IfNotPresent deploy/local/ops-scripts/new-instance.sh green

# 2. 验绿栈 (smoke / verify scripts, 改 -n 参数)
# NodePort 自动分配 (30300 范围), 看脚本输出
deploy/local/verify/02-cold-start.sh   # 默认 ns, 手动改 -n green

# 3. 切流量: 在上游 LB / Ingress 改 service 引用从 default 蓝 -> green

# 4. 拆蓝栈
kubectl delete ns fastclaw
```

## 下一步

- 见 [03-image-upgrade](03-image-upgrade.md): 升级镜像版本
- 见 [04-rollback](04-rollback.md): 出问题回退
