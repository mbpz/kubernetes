# 07 — 扩缩容 (Scaling)

## 场景

- 流量高峰 (618/双11): 临时拉更多 fastclaw pod
- 节约成本: 低峰缩到 1 副本 (注意 PDB minAvailable=1)
- 容量规划: 长期高负载, 调 HPA 上限
- 调试: 单副本排查问题, 避免多副本干扰

## 用法

```bash
# 手动扩到 3 副本 (同步调 HPA min=3, max=6)
deploy/local/ops-scripts/scale.sh fastclaw 3

# 缩到 1 副本 (注意: PDB minAvailable=1 会拒, 见下)
deploy/local/ops-scripts/scale.sh fastclaw 1

# 只改 replicas 不动 HPA (留 HPA 控)
deploy/local/ops-scripts/scale.sh fastclaw 2 --no-hpa
```

## HPA 自动扩缩

manifest 配置:
- minReplicas: 2
- maxReplicas: 4
- metric: CPU 平均利用率 60%

CPU 60% 触发 scale out, 回落缩到 min. 默认行为, 多数场景不用动.

调阈值:
```bash
kubectl -n fastclaw edit hpa fastclaw
# spec.metrics[0].resource.target.averageUtilization: 60 -> 80 (更晚扩)
```

## PDB 限制

当前 PDB `minAvailable: 1` 强制保证 1 副本可用. 缩到 0 会被 PDB 拒:
```
error: ... forbidden: PDB minAvailable=1 阻止
```

绕过 (不推荐):
```bash
kubectl -n fastclaw delete pdb fastclaw
kubectl -n fastclaw scale deploy/fastclaw --replicas=0
# 跑完恢复
kubectl -n fastclaw apply -f deploy/local/fastclaw-orbstack.yaml
```

## 资源瓶颈

| 副本数 | fastclaw 内存 (req) | M1 16G 可用 | 备注 |
|---|---|---|---|
| 1 | 128Mi | 充足 | 调试用 |
| 2 (默认) | 256Mi | 充足 | 正常 |
| 4 (HPA max) | 512Mi | 充足 | 流量高峰 |
| 6 (超 HPA 手动) | 768Mi | 紧 | 看 backend 撑不撑 |
| 8+ | 1GB+ | 风险 | 需先升 host |

**backend 瓶颈** (fastclaw 副本 > 4 后):
- postgres 单实例, 默认 max_connections=100, 4 pod 已用 ~8 conn (每个 pod 池化), 8+ pod 撞
- minio 单实例, S3 API 串行处理大文件, 多 pod 并发上传会排队

**解法**: 
- postgres HA (Patroni + 3 实例)
- minio 分布式模式 (4+ 实例, erasure coding)

## 跨 ns 扩 (默认 + 租户 + 实例)

```bash
for ns in $(kubectl get ns -l app.kubernetes.io/part-of=fastclaw-local -o name | cut -d/ -f2); do
  deploy/local/ops-scripts/scale.sh "$ns" 3
done
```

## 不在扩缩容范围

- **postgres / minio StatefulSet** 是单实例, 不扩. 需走 HA/分布式模式 (见 [09-migrate](09-migrate-to-real-cluster.md))
- **HPA** 本身不扩, 是 K8s 控制器

## 验证

```bash
# 1. 副本数对
kubectl -n fastclaw get deploy fastclaw
# 2. pod 都 Running
kubectl -n fastclaw get pods -l app=fastclaw
# 3. HPA 没在自动调
kubectl -n fastclaw get hpa
# 4. RSS 仍合规
deploy/local/verify/03-pod-rss.sh
```

## 缩到 0 (清场)

```bash
# 删 deployment 即可 (HPA/PDB/Service 留着, 重新 apply 即可恢复)
kubectl -n fastclaw delete deploy fastclaw
# 恢复
kubectl apply -f deploy/local/fastclaw-orbstack.yaml
```

## CPU 限制注意

每 pod CPU limit = 1 core. 突发流量打满时, fastclaw 进程会 throttled.
长任务 (大文件处理) 偶发 5xx. 解:
- 调高 limit: `kubectl -n fastclaw set resources deploy/fastclaw -c fastclaw --limits=cpu=2`
- 副本数 +1, 负载分摊

## 测扩容流程

```bash
# 1. 扩
deploy/local/ops-scripts/scale.sh fastclaw 4
# 2. 跑压测 (需 OPENAI_API_KEY + hey)
kubectl -n fastclaw port-forward svc/fastclaw 18953:80 &
hey -n 1000 -c 10 -H "Authorization: Bearer $(cat .admin_token)" \
  http://localhost:18953/api/agents
# 3. 看 HPA
kubectl -n fastclaw get hpa -w
# 4. 缩回
deploy/local/ops-scripts/scale.sh fastclaw 2
```
