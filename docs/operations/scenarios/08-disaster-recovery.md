# 08 — 灾难恢复 (Disaster Recovery)

## 场景

集群 / 节点全毁, PVC 丢失, etcd 损坏. 从最近一次 backup 完整重建.

## RTO / RPO 目标

| 指标 | 当前 v1 (本地) | 生产建议 |
|---|---|---|
| RPO (恢复点目标) | 上次 backup 时间 | 15min - 1h (取决于 backup 频率) |
| RTO (恢复时间目标) | 30min - 1h | < 15min (runbook 演练后) |

## 灾难清单

| 类型 | 表现 | 恢复方式 |
|---|---|---|
| 单 pod 崩 | `kubectl get pods` CrashLoopBackOff | `kubectl delete pod`, 触发 ReplicaSet 重拉 |
| 单 ns 误删 | `kubectl get ns` 找不到 | `kubectl apply` manifest 重建; **数据靠 backup** |
| 节点宕 | `kubectl get nodes` NotReady | orbstack 单节点, 启 OrbStack; k8s 自动恢复 (StatefulSet pod 重新调度) |
| etcd 损坏 | apiserver 启不来 | 集群重装, **数据靠 backup** |
| 整个 orbstack 容器丢 | orbstack 重装 | k8s 重装 + backup 恢复 |
| 物理机坏 | 硬盘坏 | 同上 |
| ransomware | 文件被加密 | 跨区/异地 backup 是唯一出路 |

## 恢复流程 (runbook)

### 步骤 0: 评估损失

```bash
# 看 etcd
docker exec orbstack-k8s-control-plane etcdctl ...   # 复杂, 跳到步骤 1
# 看 PVC 数据是否还在
kubectl get pvc -A
# 看 backup 在不在
ls -la /Volumes/Backup/fastclaw-*  # 或 S3
```

### 步骤 1: 集群重建

```bash
# 1a. orbstack 重装 (假设整个容器没了)
brew reinstall orbstack
# 启 k8s (orbstack UI / orbstack kubernetes enable)

# 1b. 装 metrics-server (verify 03 要)
kubectl apply -f deploy/local/metrics-server.yaml

# 1c. 装共享 infra
kubectl apply -f deploy/local/fastclaw-orbstack.yaml   # 默认 fastclaw ns

# 等 ready
kubectl -n fastclaw wait --for=condition=ready pod -l app.kubernetes.io/component=database --timeout=120s
kubectl -n fastclaw wait --for=condition=ready pod -l app.kubernetes.io/component=object-store --timeout=120s
kubectl -n fastclaw wait --for=condition=complete job/minio-bucket-init --timeout=60s
```

### 步骤 2: 数据恢复

```bash
# 找最近一次 backup
LATEST=$(ls -td /Volumes/Backup/fastclaw-* | head -1)
echo "用 backup: $LATEST"

# 检查 manifest
cat "$LATEST/manifest.json" | jq .

# 恢复
deploy/local/ops-scripts/restore.sh "$LATEST"
```

### 步骤 3: 重建租户/实例

backup 只恢复数据, 不知道 K8s 资源. 需重新创建:

```bash
# 看 manifest 里有哪些 ns, 一个个 new-tenant / new-instance
cat "$LATEST/manifest.json" | jq -r '.items[].ns' | sort -u
# 假设有 fastclaw-acme, staging
deploy/local/ops-scripts/new-tenant.sh acme      # 用新 secret 凭据, 后面 restore 会覆盖
deploy/local/ops-scripts/new-instance.sh staging

# 重新跑 restore 跨所有 ns
deploy/local/ops-scripts/restore.sh "$LATEST"
```

### 步骤 4: 验证

```bash
deploy/local/verify/all.sh
```

## 跨区 backup (进阶)

本地 backup 解决不了 ransomware / 物理灾难. 加 S3 远端:

```bash
# 改 backup.sh 末尾加:
tar czf - "$BACKUP_DIR" | aws s3 cp - s3://my-bucket/fastclaw-backups/${TS}.tar.gz --sse AES256
```

crontab:
```
0 3 * * * /path/to/backup.sh && \
  tar czf - $(ls -td /path/to/backups/* | head -1) | \
  aws s3 cp - s3://my-bucket/fastclaw-backups/$(date +\%Y\%m\%d).tar.gz
```

## 演练 (每年至少 1 次)

```bash
# 1. 删 ns 模拟灾难
kubectl delete ns fastclaw

# 2. 按 runbook 恢复
# (步骤 1-4)

# 3. 计时, 记录 RTO
# 4. 检查数据完整性: 抽样几个 agent / 文件 vs 上次 backup manifest
```

## 不恢复的东西

- fastclaw pod 内存状态 (重启清, 设计如此)
- K8s Event / Audit log (集群组件级, 默认不备份)
- minio console session (用户级, 不重要)

## 降级方案 (无法完整恢复)

如果 backup 损坏 / 部分缺失:

| 损坏 | 降级 |
|---|---|
| PG dump 损坏 | 用上一份 backup; 或 `pg_resetwal` 抢救 (高危) |
| minio tar 损坏 | 重跑 `mc mirror`, 部分对象丢 |
| manifest 缺 | 从目录结构反推; 跑 `gunzip -t *.sql.gz` 验 PG |
| K8s 资源全无 | 看 git log 找上次 apply 的 manifest (本仓库) |

## 通知 & 升级路径

RTO 超目标:
- 1h-4h: 业务降级 (暂停新 agent 创建, 只服务已存在 agent)
- 4h+: 业务停机, 公告

升级路径 (DR 不只是 backup):
- 异地多活 (多 region k8s 集群 + 数据库复制)
- 蓝绿跨集群 (active-active / active-passive)
- 详见 [09-migrate-to-real-cluster](09-migrate-to-real-cluster.md)
