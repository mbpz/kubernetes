# FastClaw 本地复现验证需求文档 (PRD)

- **文档编号**: 2026-06-02-fastclaw-local-repro
- **类型**: 本地复现验证 PRD
- **日期**: 2026-06-02
- **作者**: jinguo.zeng
- **工作目录**: `/Users/jinguo.zeng/dmall/project/kubernetes`

## 背景

托管服务的 MRR 突破了 8k 刀,除去运营成本,利润非常低。今天终于把服务迁移到了 FastClaw,通过存算分离的架构,让 Agent 无需常驻,而是在收到请求时动态挂载 sandbox 来提供服务。服务器从 18 台降到了 3 台,运营成本降到了 1/6,下个月有机会赚到钱了。

跟 OpenClaw 比,FastClaw 真的是太轻量了:

1. 代码体积约为 OpenClaw 的 1/40
2. 运行资源占用约为 OpenClaw 的 1/7
3. 单二进制分发,无环境依赖
4. OpenClaw 的 gateway 启动大概需要 15s,FastClaw 秒级启动

FastClaw 本身是为云原生多租户场景而设计的 Agent 运行框架,同样也适用本地运行场景。本 PRD 描述如何在个人 M1 MacBook Pro (16G 内存, 256G 固态) 上,通过 OrbStack 内置 Kubernetes 完整复现这一托管架构,用于工程师验证、demo 与回归测试。

---

## §1 目标与受众

**受众**: 在 M1 MacBook Pro (16G/256G) 上,用 OrbStack k8s 完整复现 FastClaw 托管架构的工程师。

**目标**: 在单机上验证 FastClaw 关键架构特性,不依赖任何云资源(除 E2B sandbox API):

- 存算分离 (gateway 无状态, 状态在 PG + MinIO)
- 多 pod 横向扩展 (gateway 2 副本一致性)
- Sandbox 按需挂载 (E2B 远程, 收到请求才唤起)
- 秒级冷启动
- 错误恢复 (pod kill, PG 重启, MinIO 重启)

**验收准则**:

| 指标 | 目标 | 测量方式 |
|---|---|---|
| FastClaw 二进制体积 | < OpenClaw 的 1/40 (绝对值 ≤ 80 MB) | `ls -lh ./bin/fastclaw` |
| Gateway 冷启动 | ≤ 5 s | `time kubectl rollout status` 减去镜像 pull |
| 单 pod RSS 稳态 | ≤ 200 MiB | `kubectl top pod` |
| Gateway 副本一致性 | 任一 pod 写, 另一 pod 立即可读 | 双 pod 并发 API 测试 |
| Sandbox 唤起延迟 | ≤ 3 s (E2B 默认 template) | gateway 日志时间戳 |
| 服务可用性 (单 pod kill) | 0 失败请求 | `wrk` 压测期间 `kubectl delete pod` |

---

## §2 架构

```
┌──────────────────────── M1 MBP (macOS 14+) ─────────────────────────┐
│                                                                    │
│  OrbStack VM (Linux ARM64)                                         │
│  ┌────────────────────── k8s (orbstack 内置) ────────────────────┐ │
│  │                                                              │ │
│  │  ns: fastclaw                                                │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │ │
│  │  │ fastclaw     │  │ fastclaw     │  │ postgres     │        │ │
│  │  │ -gateway-0   │  │ -gateway-1   │  │ -0 (sts)     │        │ │
│  │  │ (Deploy)     │  │ (Deploy)     │  │              │        │ │
│  │  │ 18953        │  │ 18953        │  │ 5432         │        │ │
│  │  └──────┬───────┘  └──────┬───────┘  └──────▲───────┘        │ │
│  │         │                 │                 │                │ │
│  │         │  ClusterIP svc  │      DSN env    │                │ │
│  │         └────────┬────────┘                 │                │ │
│  │                  │                          │                │ │
│  │             ┌────▼─────┐    S3 SDK    ┌─────┴────┐           │ │
│  │             │ Service  │              │ minio-0  │           │ │
│  │             │ fastclaw │              │ (sts)    │           │ │
│  │             │ ClientIP │              │ 9000     │           │ │
│  │             │ affinity │              └──────────┘           │ │
│  │             └────┬─────┘                                     │ │
│  └──────────────────┼─────────────────────────────────────────┘   │
│                     │ port-forward                                 │
└─────────────────────┼─────────────────────────────────────────────┘
                      ▼
               localhost:18953
                      │
                      │ HTTPS (E2B SDK)
                      ▼
               ┌──────────────┐
               │  E2B Cloud   │  动态 sandbox, 请求触发
               │  Sandbox     │
               └──────────────┘
```

### 2.1 组件清单

| 组件 | 类型 | 副本 | 镜像 | 备注 |
|---|---|---|---|---|
| `fastclaw` | Deployment | 2 | `ghcr.io/fastclaw-ai/fastclaw:dev` (multi-arch, ARM64 必需) | 无状态。ENV-only bootstrap |
| `postgres` | StatefulSet | 1 | `postgres:16-alpine` | PVC 10Gi。单实例验证模式 |
| `minio` | StatefulSet | 1 | `minio/minio:latest` (multi-arch) | PVC 10Gi。console 9001 |
| `fastclaw-svc` | Service ClusterIP | - | - | port 80→18953, sessionAffinity ClientIP |
| `fastclaw-hpa` | HPA | - | - | cpu 60%, min=2, max=4 (单机限制) |
| `fastclaw-pdb` | PDB | - | - | minAvailable=1 |
| `fastclaw-secrets` | Secret | - | - | STORAGE_DSN, OBJECT_STORE_AK/SK, E2B_API_KEY |
| `fastclaw-config` | ConfigMap | - | - | FASTCLAW_* env |

### 2.2 关键设计点

1. **存算分离**: gateway pod 的 `/data/.fastclaw` 仅 emptyDir, 重启即清, 所有持久态走 PG + MinIO。验证手段: 删除 pod 后副本恢复, 数据无丢。
2. **多 pod 一致性**: SQLite 单文件不支持多 pod, 故 `FASTCLAW_STORAGE_TYPE=postgres` 强制。跨 pod 写后读测试。
3. **Sandbox**: `FASTCLAW_SANDBOX_BACKEND=e2b`。orbstack k8s 内 pod 无 docker daemon, 唯一可行路径。
4. **Ingress**: 不部署。单机 `kubectl port-forward svc/fastclaw 18953:80`, 减少 nginx-ingress 依赖, 也避免 macOS host 上额外配 host name。
5. **网络**: orbstack k8s 默认 LoadBalancer 由 orbstack 桥接到 host, 故备选可直接 `type: LoadBalancer`。PRD 主路径用 port-forward。

---

## §3 资源预算与主机配置

### 3.1 M1 16G/256G 容量分配

| 用途 | 内存 | 磁盘 |
|---|---|---|
| macOS + Apps | ~5 GB | ~30 GB |
| OrbStack VM 开销 | ~1 GB | ~3 GB |
| k8s 控制面 (orbstack 内置) | ~0.8 GB | ~2 GB |
| FastClaw gateway × 2 (limit 512Mi) | ~1 GB | 镜像 ~150 MB |
| Postgres (limit 512Mi) | ~0.5 GB | PVC 10 GB |
| MinIO (limit 512Mi) | ~0.5 GB | PVC 10 GB |
| Buffer (浏览器/IDE/sandbox SDK) | ~3 GB | - |
| **占用合计** | **~12 GB** | **~55 GB** |
| **可用余量** | ~4 GB | ~200 GB |

### 3.2 OrbStack 配置要求

- 版本 ≥ 1.7 (Kubernetes 支持 ARM64 + v1.30+)
- VM CPU 分配: ≥ 6 cores (M1 Pro 总 10 核, 留 4 给 host)
- VM 内存上限: 12 GB
- VM 磁盘上限: 80 GB
- k8s engine: 启用 (Settings → Kubernetes → Enable)
- 默认 ingress class: nginx (PRD 不强制依赖)

### 3.3 Pod 资源 spec

```yaml
# fastclaw gateway
resources:
  requests: { cpu: "100m", memory: "128Mi" }
  limits:   { cpu: "1",    memory: "512Mi" }

# postgres
resources:
  requests: { cpu: "100m", memory: "256Mi" }
  limits:   { cpu: "1",    memory: "512Mi" }

# minio
resources:
  requests: { cpu: "100m", memory: "256Mi" }
  limits:   { cpu: "1",    memory: "512Mi" }
```

### 3.4 前置软件清单

| 工具 | 版本 | 用途 |
|---|---|---|
| orbstack | ≥ 1.7 | macOS 容器 + VM + k8s |
| kubectl | ≥ 1.30 | 集群管理 |
| jq | ≥ 1.6 | 验收脚本解析 |
| wrk 或 hey | 任一 | 压测验证副本一致性 |
| curl | macOS 自带 | API 烟测 |

### 3.5 外部账户

- E2B API key: 必需 (从 e2b.dev 申请, free tier 足够 demo)
- 任一 LLM provider key (OpenAI/Anthropic/OpenRouter/Ollama 任选一)

---

## §4 部署清单

文件: `deploy/local/fastclaw-orbstack.yaml`。一文件部署。顺序: Namespace → Secret/ConfigMap → Postgres → MinIO → FastClaw。

```yaml
apiVersion: v1
kind: Namespace
metadata: { name: fastclaw }

---
apiVersion: v1
kind: Secret
metadata: { name: fastclaw-secrets, namespace: fastclaw }
type: Opaque
stringData:
  STORAGE_DSN: "postgres://fastclaw:fastclaw@postgres:5432/fastclaw?sslmode=disable"
  OBJECT_STORE_ACCESSKEY: "minioadmin"
  OBJECT_STORE_SECRETKEY: "minioadmin"
  E2B_API_KEY: "REPLACE_WITH_E2B_KEY"
  OPENAI_API_KEY: "REPLACE_WITH_LLM_KEY"

---
apiVersion: v1
kind: ConfigMap
metadata: { name: fastclaw-config, namespace: fastclaw }
data:
  FASTCLAW_PORT: "18953"
  FASTCLAW_BIND: "all"
  FASTCLAW_STORAGE_TYPE: "postgres"
  FASTCLAW_STORAGE_AUTO_MIGRATE: "true"
  FASTCLAW_OBJECT_STORE_TYPE: "minio"
  FASTCLAW_OBJECT_STORE_ENDPOINT: "minio:9000"
  FASTCLAW_OBJECT_STORE_BUCKET: "fastclaw"
  FASTCLAW_OBJECT_STORE_USESSL: "false"
  FASTCLAW_SANDBOX_ENABLED: "true"
  FASTCLAW_SANDBOX_BACKEND: "e2b"
  FASTCLAW_LOG_LEVEL: "info"

---
# Postgres StatefulSet
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: postgres, namespace: fastclaw }
spec:
  serviceName: postgres
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - { name: POSTGRES_DB,       value: fastclaw }
            - { name: POSTGRES_USER,     value: fastclaw }
            - { name: POSTGRES_PASSWORD, value: fastclaw }
            - { name: PGDATA,            value: /var/lib/postgresql/data/pgdata }
          ports: [{ name: pg, containerPort: 5432 }]
          volumeMounts: [{ name: data, mountPath: /var/lib/postgresql/data }]
          resources:
            requests: { cpu: "100m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }
          readinessProbe:
            exec: { command: ["pg_isready","-U","fastclaw"] }
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 10Gi } }

---
apiVersion: v1
kind: Service
metadata: { name: postgres, namespace: fastclaw }
spec:
  clusterIP: None
  selector: { app: postgres }
  ports: [{ name: pg, port: 5432, targetPort: pg }]

---
# MinIO StatefulSet
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: minio, namespace: fastclaw }
spec:
  serviceName: minio
  replicas: 1
  selector: { matchLabels: { app: minio } }
  template:
    metadata: { labels: { app: minio } }
    spec:
      containers:
        - name: minio
          image: minio/minio:latest
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - { name: MINIO_ROOT_USER,     value: minioadmin }
            - { name: MINIO_ROOT_PASSWORD, value: minioadmin }
          ports:
            - { name: s3,      containerPort: 9000 }
            - { name: console, containerPort: 9001 }
          volumeMounts: [{ name: data, mountPath: /data }]
          resources:
            requests: { cpu: "100m", memory: "256Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }
          readinessProbe:
            httpGet: { path: /minio/health/ready, port: s3 }
            periodSeconds: 5
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 10Gi } }

---
apiVersion: v1
kind: Service
metadata: { name: minio, namespace: fastclaw }
spec:
  selector: { app: minio }
  ports:
    - { name: s3,      port: 9000, targetPort: s3 }
    - { name: console, port: 9001, targetPort: console }

---
# Bucket bootstrap Job (mc mb fastclaw)
apiVersion: batch/v1
kind: Job
metadata: { name: minio-bucket-init, namespace: fastclaw }
spec:
  backoffLimit: 5
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: minio/mc:latest
          command:
            - sh
            - -c
            - |
              mc alias set local http://minio:9000 minioadmin minioadmin
              mc mb --ignore-existing local/fastclaw

---
# FastClaw Deployment
apiVersion: apps/v1
kind: Deployment
metadata: { name: fastclaw, namespace: fastclaw }
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }
  selector: { matchLabels: { app: fastclaw } }
  template:
    metadata: { labels: { app: fastclaw } }
    spec:
      containers:
        - name: fastclaw
          image: ghcr.io/fastclaw-ai/fastclaw:dev
          imagePullPolicy: IfNotPresent
          ports: [{ name: http, containerPort: 18953 }]
          envFrom: [{ configMapRef: { name: fastclaw-config } }]
          env:
            - { name: FASTCLAW_HOME, value: "/data/.fastclaw" }
            - { name: FASTCLAW_STORAGE_DSN,            valueFrom: { secretKeyRef: { name: fastclaw-secrets, key: STORAGE_DSN } } }
            - { name: FASTCLAW_OBJECT_STORE_ACCESSKEY, valueFrom: { secretKeyRef: { name: fastclaw-secrets, key: OBJECT_STORE_ACCESSKEY } } }
            - { name: FASTCLAW_OBJECT_STORE_SECRETKEY, valueFrom: { secretKeyRef: { name: fastclaw-secrets, key: OBJECT_STORE_SECRETKEY } } }
            - { name: E2B_API_KEY,                     valueFrom: { secretKeyRef: { name: fastclaw-secrets, key: E2B_API_KEY } } }
            - { name: OPENAI_API_KEY,                  valueFrom: { secretKeyRef: { name: fastclaw-secrets, key: OPENAI_API_KEY } } }
          volumeMounts: [{ name: data, mountPath: /data/.fastclaw }]
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /livez, port: http }
            initialDelaySeconds: 30
            periodSeconds: 30
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "1",    memory: "512Mi" }
          lifecycle:
            preStop: { exec: { command: ["sh","-c","sleep 15"] } }
      terminationGracePeriodSeconds: 30
      volumes: [{ name: data, emptyDir: {} }]

---
apiVersion: v1
kind: Service
metadata: { name: fastclaw, namespace: fastclaw }
spec:
  type: ClusterIP
  selector: { app: fastclaw }
  sessionAffinity: ClientIP
  sessionAffinityConfig: { clientIP: { timeoutSeconds: 3600 } }
  ports: [{ name: http, port: 80, targetPort: http }]

---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: fastclaw, namespace: fastclaw }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: fastclaw }
  minReplicas: 2
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 60 }

---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: fastclaw, namespace: fastclaw }
spec:
  minAvailable: 1
  selector: { matchLabels: { app: fastclaw } }
```

### 4.1 部署命令

```bash
kubectl apply -f deploy/local/fastclaw-orbstack.yaml
kubectl -n fastclaw rollout status deploy/fastclaw --timeout=120s
kubectl -n fastclaw port-forward svc/fastclaw 18953:80
```

### 4.2 首次 super_admin 创建

```bash
kubectl -n fastclaw exec deploy/fastclaw -- \
  fastclaw admin create-user --username alice \
    --email alice@example.com --password 'hunter2' \
    --role super_admin
```

### 4.3 获取 API token (供验收脚本使用)

```bash
# 创建一个 admin 级 apikey, 保存到 .admin_token
kubectl -n fastclaw exec deploy/fastclaw -- \
  fastclaw apikey create --username alice --tier admin --name verify \
  | awk '/^Token:/ {print $2}' > .admin_token
chmod 600 .admin_token
```

`.admin_token` 文件被 §6 验收脚本读取。`fastclaw apikey create` 命令仅打印一次明文 token, 故必须当场保存。

---

## §5 数据流

### 5.1 典型请求路径 (调用 agent + tool 触发 sandbox)

```
1. client                  POST localhost:18953/v1/chat/completions
                                  │  X-Fastclaw-End-User: u_xxx
                                  ▼
2. port-forward         →  Service ClusterIP fastclaw:80
                                  │  sessionAffinity ClientIP
                                  ▼
3. Service              →  fastclaw-gateway-0 (or -1)
                                  │
                                  ▼
4. gateway 鉴权          (DB users + apikeys, scope=user|admin|agent)
                                  │
                                  ▼
5. gateway 加载 agent    SELECT agent_files, configs FROM PG
                                  │  miss: 走 ObjectStore 拉技能包
                                  ▼
6. gateway 调用 LLM      HTTPS → OpenAI/Anthropic API
                                  │  (token cache, RawAssistant 保留)
                                  ▼
7. LLM 返回 tool_call    e.g. exec("ls /workspace")
                                  │
                                  ▼
8. gateway 唤起 sandbox  E2B SDK: createSandbox(template, env)
                                  │  按需创建 (~3s 冷启动)
                                  ▼
9. sandbox 执行          E2B 远程容器内 run
                                  │
                                  ▼
10. sandbox 同步         post-exec: 文件改动回写 MinIO
                                  │  workspace artifacts → /fastclaw/<sid>/...
                                  ▼
11. gateway 写 session   INSERT sessions/messages → PG
                                  │
                                  ▼
12. SSE 流回 client      response chunked
```

### 5.2 关键持久化拓扑

| 数据类别 | 写入点 | 存储后端 | 跨 pod 共享? |
|---|---|---|---|
| user / apikey / agent records | gateway | PG `users` / `apikeys` / `agents` | 是 |
| Session / message 历史 | gateway | PG `sessions` / `messages` | 是 |
| Agent 系统文件 (SOUL/IDENTITY/...) | gateway / CLI | PG `agent_files` | 是 |
| 全局 skill 文件 | gateway | MinIO `skills/<sha>/` | 是 (各 pod hydrate 到本地 emptyDir cache) |
| Sandbox workspace artifacts | sandbox post-exec | MinIO `workspaces/<sid>/` | 是 |
| 临时 sandbox cache | gateway | pod emptyDir `/data/.fastclaw` | 否 (重启清) |

### 5.3 多 pod 一致性保证

- 写: 所有写操作走 PG / MinIO 事务 → 立即对其他 pod 可见
- 读: 各 pod 无本地缓存的"权威态", 命中 PG / MinIO 即新鲜
- 例外: skill 文件 hydrate 缓存在 pod 本地, 命中 sha 后跳过下载。skill 更新会 bump sha, 旧 pod 下次拉新 sha 时重 hydrate

### 5.4 SSE / WebSocket 黏滞

- Service `sessionAffinity: ClientIP` (1h)
- 单 client 在 1h 内 SSE / WS 都打到同一 pod, 避免重连风暴
- pod 被驱逐时, preStop sleep 15s + termGrace 30s, 给 SSE 排空时间

---

## §6 验收测试

演示脚本目录: `deploy/local/verify/`。每个验收点对应 1 个脚本, 返回非零退出码即失败。

### 6.1 资源指标验收

```bash
# verify/01-binary-size.sh
docker run --rm --entrypoint sh ghcr.io/fastclaw-ai/fastclaw:dev \
  -c 'wc -c < /usr/local/bin/fastclaw' | \
  awk '{ if ($1 > 80*1024*1024) { print "FAIL: "$1" > 80MB"; exit 1 } else { print "OK: "$1" bytes" } }'

# verify/02-cold-start.sh
kubectl -n fastclaw scale deploy/fastclaw --replicas=0
kubectl -n fastclaw wait --for=delete pod -l app=fastclaw --timeout=60s
t0=$(date +%s)
kubectl -n fastclaw scale deploy/fastclaw --replicas=2
kubectl -n fastclaw wait --for=condition=ready pod -l app=fastclaw --timeout=30s
t1=$(date +%s)
elapsed=$((t1-t0))
[ $elapsed -le 5 ] || { echo "FAIL: cold start ${elapsed}s > 5s"; exit 1; }
echo "OK: cold start ${elapsed}s"

# verify/03-pod-rss.sh
kubectl -n fastclaw top pod -l app=fastclaw --no-headers | \
  awk '{ gsub(/Mi/,"",$3); if ($3+0 > 200) { print "FAIL: "$1" RSS="$3"Mi > 200Mi"; exit 1 } else { print "OK: "$1" RSS="$3"Mi" } }'
```

### 6.2 多 pod 一致性验收

```bash
# verify/04-multipod-consistency.sh
POD0=$(kubectl -n fastclaw get pod -l app=fastclaw -o name | sed -n 1p)
POD1=$(kubectl -n fastclaw get pod -l app=fastclaw -o name | sed -n 2p)

kubectl -n fastclaw exec "$POD0" -- fastclaw agents init test-agent \
  --provider openai --model gpt-4o-mini --api-key-env OPENAI_API_KEY

RESULT=$(kubectl -n fastclaw exec "$POD1" -- fastclaw agents ls | grep test-agent)
[ -n "$RESULT" ] || { echo "FAIL: pod1 没看到 pod0 创建的 agent"; exit 1; }
echo "OK: cross-pod read 一致"
```

### 6.3 Sandbox 唤起验收

> macOS 默认无 `gdate`, 需 `brew install coreutils`, 或将 `gdate` 替换为 `python3 -c 'import time;print(time.time())'`。

```bash
# verify/05-sandbox-cold.sh
TOKEN=$(cat .admin_token)
T0=$(gdate +%s.%N)
curl -sN -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"运行 ls / 并告诉我结果"}],"stream":true}' \
     localhost:18953/v1/chat/completions > /tmp/sse.log
T1=$(gdate +%s.%N)
ELAPSED=$(echo "$T1 - $T0" | bc)
awk -v e="$ELAPSED" 'BEGIN{ if (e+0 > 3.0) { print "FAIL: sandbox cold "e"s > 3s"; exit 1 } else { print "OK: sandbox cold "e"s" } }'
```

### 6.4 存算分离验收 (pod kill)

```bash
# verify/06-statelessness.sh
kubectl -n fastclaw delete pod -l app=fastclaw --grace-period=0 --force
kubectl -n fastclaw wait --for=condition=ready pod -l app=fastclaw --timeout=30s

SESSION_COUNT=$(kubectl -n fastclaw exec deploy/fastclaw -- \
  fastclaw agents files ls test-agent | wc -l)
[ "$SESSION_COUNT" -gt 0 ] || { echo "FAIL: 重启后 agent 文件丢失"; exit 1; }
echo "OK: 重启后状态完整"
```

### 6.5 持续可用性验收 (滚动压测)

```bash
# verify/07-rolling-availability.sh
hey -n 5000 -c 20 -H "Authorization: Bearer $TOKEN" \
    localhost:18953/api/agents > /tmp/hey.log &
HEY_PID=$!
sleep 5
kubectl -n fastclaw delete pod $(kubectl -n fastclaw get pod -l app=fastclaw -o name | head -1)
wait $HEY_PID

NON_2XX=$(grep -E "Status code distribution" -A 10 /tmp/hey.log | grep -E "\[[45]" | awk '{sum+=$2} END {print sum+0}')
[ "$NON_2XX" -eq 0 ] || { echo "FAIL: $NON_2XX 个非 2xx"; exit 1; }
echo "OK: 0 失败请求"
```

### 6.6 主控验收脚本

> 顺序约定: `01` → `07` 严格按数字顺序执行。`04-multipod-consistency.sh` 创建的 `test-agent` 被 `06-statelessness.sh` 复用, 故 06 必须晚于 04。`all.sh` 用 glob `0*.sh` 已保证 lexicographic 顺序与 numeric 顺序一致。

```bash
# verify/all.sh
set -e
for s in verify/0*.sh; do
  echo "─── running $s ───"
  bash "$s"
done
echo "ALL VERIFY PASS"
```

---

## §7 错误恢复场景

| 故障 | 触发命令 | 预期行为 | 验收 |
|---|---|---|---|
| 单 gateway pod 崩溃 | `kubectl -n fastclaw delete pod fastclaw-xxx` | 另一 pod 接管, PDB 保证 ≥1 在线 | 压测期间 0 失败 |
| 全部 gateway pod 同时挂 | `kubectl -n fastclaw scale deploy/fastclaw --replicas=0 && --replicas=2` | 重启后 PG / MinIO 数据完整, agent 列表恢复 | §6.4 脚本 |
| Postgres 重启 | `kubectl -n fastclaw delete pod postgres-0` | gateway 失败请求 ≤ pg readinessProbe 周期 (5s) 后恢复 | 5s 内请求复测 200 |
| MinIO 重启 | `kubectl -n fastclaw delete pod minio-0` | sandbox 同步暂停, 重启后 post-exec sync 重试成功 | workspace 文件无丢 |
| Pod 内存超 limit (OOMKill) | 注入大请求 / 调小 limit 触发 | kubelet 重启 pod, PDB 触发等待 | restart count +1, 业务无 5xx 持久化 |
| E2B 网络不可达 | iptables block e2b.dev | sandbox tool_call 返回错误, gateway 不崩, 非 sandbox 路径仍可用 | `/api/agents` 仍 200 |
| port-forward 中断 | 杀 kubectl 进程 | 重启 port-forward 立即可用 (Service ClientIP 黏滞 1h 复用) | curl 复测 200 |

手动 drill 脚本: `deploy/local/drills/`, 一目录对应一项。每个 drill 末尾打印 PASS / FAIL。

---

## §8 风险与假设

### 8.1 假设

1. `ghcr.io/fastclaw-ai/fastclaw:dev` 多架构镜像包含 `linux/arm64` manifest。**未验证** (匿名 GHCR API 401)。部署首步即可识别失败。兜底: 自行 `make build` 后 build local image。
2. E2B 服务在中国大陆访问稳定。若不稳, 改 `FASTCLAW_SANDBOX_BACKEND=docker` 并迁出 k8s, 或自部署 sandbox。
3. orbstack k8s 默认 StorageClass 支持 `ReadWriteOnce` PVC。已知 orbstack ≥ 1.7 内置 local-path provisioner。
4. M1 16G 实际可用内存 ≥ 8GB (即 macOS + IDE 不占 > 8GB)。若日常已超, 关闭重型 app 后再跑。

### 8.2 已知风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| HPA `maxReplicas=4` 在 M1 16G 上压满 | OOM 全集群挂 | 限定压测并发, 不主动触发 scaleout 到 4 |
| MinIO PVC 占满 (sandbox 频繁写大文件) | 写失败 | PVC 10Gi + 验收脚本清 workspace |
| LLM provider key 计费失控 | 钱包流血 | demo 用 gpt-4o-mini, 验收脚本限请求数 ≤ 100 |
| Service `sessionAffinity: ClientIP` 在 port-forward 后所有 client 看似单 IP | HPA 触发但流量都打一个 pod | 验证一致性时绕过 svc, 直接 `kubectl exec` 进各 pod |
| 镜像 `:dev` 滚动更新无版本锁 | 复现不可重复 | PRD 验收前固定到具体 SHA, 写入 deploy yaml |

### 8.3 显式不在本 PRD 范围

- OpenClaw 部署与并行对比 (narrative 数据作为参考目标)
- Ingress + TLS + Cert-manager
- Knative scale-to-0 (orbstack 默认 k8s 不带 Knative; 现有 `agent-service.yaml` 仅作为 sandbox dummy 对照, 不进入 FastClaw 主架构)
- 生产级 Postgres HA (本地单实例足够)
- 跨节点调度 (orbstack 单节点)

---

## 参考资料

- FastClaw 仓库: https://github.com/fastclaw-ai/fastclaw
- 官方 k8s 模板: https://github.com/fastclaw-ai/fastclaw/blob/dev/deploy/k8s/fastclaw.yaml
- E2B Sandbox: https://e2b.dev
- OrbStack Kubernetes: https://docs.orbstack.dev/kubernetes/
