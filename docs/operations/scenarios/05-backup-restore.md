# 05 — 备份与恢复 (Backup / Restore)

## 场景

- 升级前快照: 出问题立即回退
- 周期性归档: 周/日 cron 跑 backup.sh
- 灾难前预防: 详见 [08-disaster-recovery](08-disaster-recovery.md)
- 误删恢复: 删了 agent / bucket 数据, 从最近 backup 拉回

## 备份

```bash
deploy/local/ops-scripts/backup.sh
# 或指定目录
deploy/local/ops-scripts/backup.sh /Volumes/Backup/fastclaw-20260608
```

输出结构:
```
backups/20260608-135643/
├── manifest.json
├── pg-fastclaw-fastclaw.sql.gz                # 默认 ns PG dump
├── minio-fastclaw-fastclaw.tar.gz             # 默认 ns bucket
├── pg-fastclaw-acme-fastclaw_acme.sql.gz      # 租户 acme (如有)
└── minio-fastclaw-acme-fastclaw-acme.tar.gz
```

### 备份内容

| 来源 | 工具 | 备注 |
|---|---|---|
| PG 数据库 | `pg_dump` 进 postgres pod, gzip 输出 | `--no-owner --clean`, 含 schema + data |
| minio bucket | `mc mirror` 拉对象, tar 打包 | 容器内无持久, 借 /tmp 暂存 |

### 自动备份 (cron)

```bash
# /etc/cron.d/fastclaw-backup (root)
0 3 * * * jinguo.zeng /Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/ops-scripts/backup.sh /Volumes/Backup/fastclaw-\$(date +\%Y\%m\%d) && \
                       find /Volumes/Backup -name "fastclaw-*" -mtime +30 -exec rm -rf {} \;
```

保留 30 天.

### 备份大小

- 实际数据驱动. demo 阶段 PG ~10KB, bucket ~1KB
- 100 个 agent + 1GB 文件: PG ~5MB, bucket ~1GB

## 恢复

```bash
deploy/local/ops-scripts/restore.sh ./backups/20260608-135643
# 恢复到不同 ns (例如把 fastclaw 备份恢复到 staging)
deploy/local/ops-scripts/restore.sh ./backups/20260608-135643 fastclaw-stage
```

### ⚠️ 覆盖式

- PG 用 `pg_dump --clean`: 删表重建
- minio 用 `mc mirror --remove`: 目标 bucket 现有对象会被删

恢复前**强烈建议**再 backup 一次当前状态, 避免覆盖错.

### 恢复后必做

```bash
# 1. 滚动 fastclaw (内存里 agent/session 缓存 reload)
kubectl -n fastclaw rollout restart deploy/fastclaw

# 2. 验证
deploy/local/verify/all.sh
```

## 备份策略

| 维度 | 当前 (v1) | 生产建议 |
|---|---|---|
| 频率 | 手动 / 临时 cron | RPO 决定 (15min / 1h / 1d) |
| 目标 | 本地 `./backups/` | S3 / GCS / OSS + 跨区 |
| 保留 | 手动清理 | 30/90/365 天分级 |
| 加密 | 无 | `age` / GPG 加密 tar |
| 校验 | 手动 | 跑 `pg_restore --list` + 抽样 |
| 监控 | 无 | 上次成功备份时间告警 |

## 部分恢复 (单租户)

`restore.sh` 默认恢复 manifest 里所有项. 想只恢复某个 ns 的 db, 改 manifest 后再跑:

```bash
jq '.items |= map(select(.ns == "fastclaw-acme"))' \
   ./backups/20260608-135643/manifest.json > /tmp/manifest-acme.json
# (脚本暂不支持指定 manifest, 改用 jq 过滤后手动跑 psql / mc mirror)
```

## 跨集群恢复

把 `backups/<ts>/` 目录 tar 传到目标集群, 在目标机器上:
```bash
scp -r backups/20260608-135643/ target-cluster:/tmp/
ssh target-cluster "cd /path/to/kubernetes && \
  deploy/local/ops-scripts/restore.sh /tmp/20260608-135643"
```

## 不在备份范围

- fastclaw pod `/data/.fastclaw/skills/` (emptyDir, 每次 pod 重建从镜像读)
- K8s ConfigMap / Secret (manifest 即可重建)
- metrics-server / kube-system (集群组件, 走集群自身备份)

## 验证备份完整性

```bash
# 1. 跑 pg_restore --list 看 schema (不真恢复, 只解析)
gunzip -c backups/20260608-135643/pg-fastclaw-fastclaw.sql.gz > /tmp/dump.sql
grep -E "^CREATE TABLE|^CREATE INDEX" /tmp/dump.sql | head -20

# 2. 看 minio tar 里的对象
tar tzf backups/20260608-135643/minio-fastclaw-fastclaw.tar.gz | head -20
```

## 常见失败

| 现象 | 原因 | 解决 |
|---|---|---|
| `pg_dump: connection failed` | postgres pod 未就绪 | 等 STS ready, 或 `kubectl get pods -n fastclaw` |
| `mc mirror` 退出非零 | bucket 不存在 / 凭据错 | 检查 `mc alias set` 是否成功, bucket 名拼写 |
| 备份目录 0 字节 | minio 容器 /tmp 满了 | 备份前 `kubectl exec minio -- rm -rf /tmp/old-backups` |
| restore 后 verify FAIL | PG schema 不匹配 fastclaw 版本 | 用同版本 fastclaw 镜像跑 `auto-migrate` 或手动 migrate |
