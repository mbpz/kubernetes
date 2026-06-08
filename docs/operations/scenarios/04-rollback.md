# 04 — 回滚 (Rollback)

## 场景

升级后发现问题 (启动失败, RSS 飙高, 接口 500, verify 退化), 需要立即回到上一稳定版本.

## 用法

### 一步回滚到上一版本

```bash
deploy/local/ops-scripts/rollback.sh
```

### 回滚到指定历史版本

```bash
# 1. 看历史
kubectl -n fastclaw rollout history deploy/fastclaw

# 输出:
# REVISION  CHANGE-CAUSE
# 1         kubectl set image deploy/fastclaw fastclaw=fastclaw:v1.2.2 --record=true
# 2         kubectl set image deploy/fastclaw fastclaw=fastclaw:v1.2.3 --record=true
# 3         kubectl set image deploy/fastclaw fastclaw=fastclaw:local  --record=true   # 当前

# 2. 回滚到 revision 2
kubectl -n fastclaw rollout undo deploy/fastclaw --to-revision=2
```

### 跨所有 ns

```bash
deploy/local/ops-scripts/rollback.sh --all
```

## 脚本做了什么

- `kubectl rollout undo deploy/<name>`: 跳到上一 ReplicaSet 的 PodTemplate
- 等 `rollout status` 完成 (rolling update 替换 pod)
- `--all` 模式: 跨所有 gateway 部署逐个 undo

## K8s 历史保留

- `deployment.spec.revisionHistoryLimit` 默认 10 (manifest 里没改, 沿用默认)
- 超过 10 个版本的最早历史会被 GC, 不能再 undo
- 想保留更多: 改 manifest, 加 `spec.revisionHistoryLimit: 50`

## 回滚失败排查

### 镜像已被 GC

`kubectl rollout undo` 改 PodTemplate 引用旧 ReplicaSet 的镜像, 但**实际 pod 拉镜像**是 kubelet 行为.
如果旧镜像在 node 上没缓存 (集群重启 / 节点替换), 拉不到就 ImagePullBackOff.

解决:
- 本地: `docker images | grep <old-tag>`, 没有就 `docker pull` 或重 build
- 远端: registry tag 还在? (CI 可能清理旧 tag, 提前配 retention 策略)

### 配置已删, 旧 ReplicaSet 引用了已删 ConfigMap

升级时改了 ConfigMap key 名, 回滚后旧 pod 找不到旧 key -> CrashLoopBackOff.

解决:
- 提前备份 ConfigMap: `kubectl get cm -o yaml > cm-backup.yaml`
- 回滚后对比新旧 ReplicaSet 引用, 必要时手动 apply 旧 ConfigMap

### 数据库 schema 兼容

回滚到旧 fastclaw 版本, 但新版本已经做过 schema migration -> 旧版本读不懂新字段.

最坏情况: 数据损坏. **强烈建议** 升级前 `deploy/local/ops-scripts/backup.sh` 备份 (见 [05-backup-restore](05-backup-restore.md)).

### 想"反向迁移" schema

新 -> 旧: 需旧版本 fastclaw 跑 `auto-migrate` 不会回退 (PG 不会自动降级 schema).
手工: `kubectl -n fastclaw exec -i statefulset/postgres -- psql -U fastclaw -d fastclaw` 改字段, **高危**.

## 蓝绿回滚

如果用蓝绿 (见 [03-image-upgrade § 蓝绿](03-image-upgrade.md#蓝绿发布-不用---all)):
- 出问题不用 rollback.sh, 直接把上游切回蓝栈, 然后 `kubectl delete ns green`
- 蓝绿无 ReplicaSet 历史可用, 但绿栈 pod 没被改, 仍跑旧镜像

## 验证回滚成功

```bash
kubectl -n fastclaw rollout status deploy/fastclaw   # deployment "fastclaw" successfully rolled out
kubectl -n fastclaw get pods -o jsonpath='{.items[*].spec.containers[0].image}'   # 旧 tag
deploy/local/verify/all.sh   # 跑全量验收
```

## 紧急止血 (rollback 也救不了)

万一 K8s 自身坏 (etcd 损坏, kubelet 死循环), 跳过 K8s 直接 docker 进 pod:
- `docker exec -it <container> sh` 进 fastclaw 容器
- 改 `~/.fastclaw/config` 或 `agents.api_key` 临时止血
- 不推荐 — K8s 终态会覆盖回 pod spec
