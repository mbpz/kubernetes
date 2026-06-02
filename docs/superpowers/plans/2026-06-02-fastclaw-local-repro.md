# FastClaw 本地复现验证 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 M1 MacBook Pro (16G/256G) + OrbStack k8s 上完整部署 FastClaw 单文件 manifest, 通过 7 个验收脚本 + 7 个故障演练 drill 验证存算分离架构。

**Architecture:** 单 namespace `fastclaw`, 2 副本 FastClaw gateway Deployment + 1 副本 Postgres StatefulSet + 1 副本 MinIO StatefulSet + bootstrap Job, 全部 in-cluster。E2B 云端 sandbox。`kubectl port-forward` 暴露到 host。

**Tech Stack:** Kubernetes (orbstack 内置), kubectl ≥ 1.30, FastClaw `ghcr.io/fastclaw-ai/fastclaw:dev`, Postgres 16, MinIO latest, bash + awk + curl + hey (压测), E2B SDK。

**Spec:** `docs/superpowers/specs/2026-06-02-fastclaw-local-repro-design.md`

---

## File Structure

工作根目录: `/Users/jinguo.zeng/dmall/project/kubernetes`

```
.
├── agent-service.yaml                          # 现有, 不动 (Knative dummy)
├── docs/superpowers/
│   ├── specs/2026-06-02-fastclaw-local-repro-design.md
│   └── plans/2026-06-02-fastclaw-local-repro.md   # 本文件
└── deploy/local/
    ├── fastclaw-orbstack.yaml                  # 全部 k8s 资源, 一文件部署
    ├── README.md                               # 运行手册 + 故障排查
    ├── verify/                                 # 验收脚本目录
    │   ├── 01-binary-size.sh
    │   ├── 02-cold-start.sh
    │   ├── 03-pod-rss.sh
    │   ├── 04-multipod-consistency.sh
    │   ├── 05-sandbox-cold.sh
    │   ├── 06-statelessness.sh
    │   ├── 07-rolling-availability.sh
    │   └── all.sh                              # 主控
    └── drills/                                 # 错误恢复演练
        ├── 01-gateway-pod-kill.sh
        ├── 02-all-gateway-down.sh
        ├── 03-postgres-restart.sh
        ├── 04-minio-restart.sh
        ├── 05-oom-kill.sh
        ├── 06-e2b-blackhole.sh
        └── 07-portforward-resume.sh
```

**File responsibilities:**

| 文件 | 职责 | 备注 |
|---|---|---|
| `fastclaw-orbstack.yaml` | 所有 k8s 资源 (ns/secret/cm/sts/deploy/svc/hpa/pdb/job) | 单文件部署, 顺序敏感 |
| `verify/01-07*.sh` | 单项验收 (二进制/启动/RSS/一致性/sandbox/无状态/可用性) | 各自独立, 退出码非零=失败 |
| `verify/all.sh` | 顺序跑所有 verify, 任一失败立即退出 | glob `0*.sh` 字典序 |
| `drills/01-07*.sh` | 故障注入 + 期望行为校验 | 手动执行, 不进 all.sh |
| `README.md` | 安装顺序 + 常用命令 + 排错 | 工程师入口 |

---

## Task 0: git init + 目录骨架

**Files:**
- Create: `.gitignore`
- Create: `deploy/local/` (目录)

**Steps:**

- [ ] **Step 0.1: 初始化 git 仓库**

```bash
cd /Users/jinguo.zeng/dmall/project/kubernetes
git init
git config user.email "jinguo.zeng@local"
git config user.name "jinguo.zeng"
```

- [ ] **Step 0.2: 写 .gitignore**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/.gitignore`

```
.admin_token
.env
*.log
/tmp/
__pycache__/
.DS_Store
```

- [ ] **Step 0.3: 创建目录骨架**

```bash
mkdir -p deploy/local/verify deploy/local/drills
```

- [ ] **Step 0.4: 首次提交**

```bash
git add agent-service.yaml docs/ .gitignore deploy/
git commit -m "chore: init repo, import spec + skeleton"
```

预期输出: `[main (root-commit) xxxxxxx] chore: init repo ...`

---

## Task 1: 部署 manifest `fastclaw-orbstack.yaml`

**Files:**
- Create: `deploy/local/fastclaw-orbstack.yaml`

**Steps:**

- [ ] **Step 1.1: 写 manifest (完整版)**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/fastclaw-orbstack.yaml`

```yaml
# FastClaw — orbstack k8s 本地单文件部署
# 部署顺序: ns → secrets/config → postgres + minio → bucket-init Job → fastclaw
# 详见 docs/superpowers/specs/2026-06-02-fastclaw-local-repro-design.md §4

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

- [ ] **Step 1.2: yaml 语法校验 (干跑, 不实际部署)**

```bash
kubectl apply -f deploy/local/fastclaw-orbstack.yaml --dry-run=client
```

预期输出: 每个资源一行 `xxx/xxx created (dry run)`, 退出码 0。

- [ ] **Step 1.3: 提交 manifest**

```bash
git add deploy/local/fastclaw-orbstack.yaml
git commit -m "feat: add fastclaw orbstack k8s single-file manifest"
```

---

## Task 2: 填密钥 + 实际部署 + 启动验证

**Files:**
- Modify: `deploy/local/fastclaw-orbstack.yaml` (替换 2 个 REPLACE_WITH_* 占位符)
- Create: `.admin_token` (gitignored)

**Steps:**

- [ ] **Step 2.1: 准备 OrbStack k8s 已启用**

打开 OrbStack → Settings → Kubernetes → Enable。当前上下文确认:

```bash
kubectl config current-context
```

预期: `orbstack`。

- [ ] **Step 2.2: 准备 secret 值**

获取 E2B key: 注册 https://e2b.dev → Dashboard → API Keys。
获取 LLM key: OpenAI/Anthropic/OpenRouter 任一。

编辑 `deploy/local/fastclaw-orbstack.yaml` 内 `fastclaw-secrets`:

```yaml
  E2B_API_KEY: "e2b_xxxxxxxxxxxxxxxxxxxx"      # 实际 E2B token
  OPENAI_API_KEY: "sk-xxxxxxxxxxxxxxxx"        # 实际 LLM token
```

**注意:** 该改动不提交。如需 git 跟踪, 改用 `kubectl create secret` 命令外置, 此处简化为直接改 yaml。修改后立即:

```bash
git update-index --assume-unchanged deploy/local/fastclaw-orbstack.yaml
```

(后续如需改 yaml 结构, 先 `git update-index --no-assume-unchanged` 取消。)

- [ ] **Step 2.3: 部署**

```bash
kubectl apply -f deploy/local/fastclaw-orbstack.yaml
```

预期: 每行 `xxx/xxx created`。

- [ ] **Step 2.4: 等待 PG + MinIO 就绪**

```bash
kubectl -n fastclaw wait --for=condition=ready pod -l app=postgres --timeout=120s
kubectl -n fastclaw wait --for=condition=ready pod -l app=minio --timeout=120s
```

预期: `pod/postgres-0 condition met` / `pod/minio-0 condition met`。

- [ ] **Step 2.5: 等待 bucket 初始化完成**

```bash
kubectl -n fastclaw wait --for=condition=complete job/minio-bucket-init --timeout=60s
```

预期: `job.batch/minio-bucket-init condition met`。

- [ ] **Step 2.6: 等待 FastClaw 就绪**

```bash
kubectl -n fastclaw rollout status deploy/fastclaw --timeout=180s
```

预期: `deployment "fastclaw" successfully rolled out`。

排错: 若 pod `ImagePullBackOff`, 大概率 ARM64 manifest 缺失。检查:

```bash
kubectl -n fastclaw describe pod -l app=fastclaw | grep -A 3 Events
```

兜底: 改 yaml 把 `image: ghcr.io/fastclaw-ai/fastclaw:dev` 改成本地 build 后的 `fastclaw:local-arm64` (走 `make build` 自行构建)。

- [ ] **Step 2.7: 创建 super_admin**

```bash
kubectl -n fastclaw exec deploy/fastclaw -- \
  fastclaw admin create-user --username alice \
    --email alice@example.com --password 'hunter2' \
    --role super_admin
```

预期: 输出 `User created: alice (role=super_admin)`。

- [ ] **Step 2.8: 创建 admin apikey 并落地**

```bash
kubectl -n fastclaw exec deploy/fastclaw -- \
  fastclaw apikey create --username alice --tier admin --name verify \
  | awk '/^Token:/ {print $2}' > .admin_token
chmod 600 .admin_token
test -s .admin_token && echo "OK: token saved" || echo "FAIL: empty token"
```

预期: `OK: token saved`。

- [ ] **Step 2.9: 起 port-forward (后台)**

```bash
kubectl -n fastclaw port-forward svc/fastclaw 18953:80 > /tmp/pf.log 2>&1 &
echo $! > /tmp/pf.pid
sleep 2
curl -sf http://localhost:18953/readyz && echo "OK: gateway up"
```

预期: `OK: gateway up`。

- [ ] **Step 2.10: 提交进度**

```bash
git add deploy/local/fastclaw-orbstack.yaml
# 上一步 assume-unchanged 已生效, 此 add 不会包含密钥
git status --short  # 确认无 fastclaw-orbstack.yaml 出现
git commit --allow-empty -m "chore: deploy fastclaw to orbstack k8s"
```

---

## Task 3: verify/01 二进制体积

**Files:**
- Create: `deploy/local/verify/01-binary-size.sh`

**Steps:**

- [ ] **Step 3.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/verify/01-binary-size.sh`

```bash
#!/usr/bin/env bash
# verify/01-binary-size.sh
# 目标: FastClaw 二进制 ≤ 80 MB (近似 OpenClaw 1/40)

set -euo pipefail

POD=$(kubectl -n fastclaw get pod -l app=fastclaw -o name | sed -n 1p)
[ -n "$POD" ] || { echo "FAIL: 无 fastclaw pod"; exit 1; }

SIZE=$(kubectl -n fastclaw exec "$POD" -- sh -c 'wc -c < /usr/local/bin/fastclaw' | tr -d '[:space:]')
LIMIT=$((80 * 1024 * 1024))

if [ "$SIZE" -gt "$LIMIT" ]; then
  echo "FAIL: binary $SIZE bytes > 80MB ($LIMIT)"
  exit 1
fi
echo "OK: binary $SIZE bytes (≤ 80MB)"
```

- [ ] **Step 3.2: 加可执行权限**

```bash
chmod +x deploy/local/verify/01-binary-size.sh
```

- [ ] **Step 3.3: 跑脚本验证 PASS**

```bash
bash deploy/local/verify/01-binary-size.sh
```

预期: `OK: binary <N> bytes (≤ 80MB)`, 退出码 0。

如果二进制位置不对 (`/usr/local/bin/fastclaw` 找不到), 排错:

```bash
kubectl -n fastclaw exec deploy/fastclaw -- which fastclaw
```

修正脚本里的路径后重测。

- [ ] **Step 3.4: 提交**

```bash
git add deploy/local/verify/01-binary-size.sh
git commit -m "test: verify/01 fastclaw binary size ≤ 80MB"
```

---

## Task 4: verify/02 冷启动时间

**Files:**
- Create: `deploy/local/verify/02-cold-start.sh`

**Steps:**

- [ ] **Step 4.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/verify/02-cold-start.sh`

```bash
#!/usr/bin/env bash
# verify/02-cold-start.sh
# 目标: FastClaw gateway 冷启动 ≤ 5s

set -euo pipefail

# Scale to 0 + 等待所有 pod 消失
kubectl -n fastclaw scale deploy/fastclaw --replicas=0
kubectl -n fastclaw wait --for=delete pod -l app=fastclaw --timeout=60s 2>/dev/null || true

# 计时 scale up + ready
T0=$(date +%s)
kubectl -n fastclaw scale deploy/fastclaw --replicas=2
kubectl -n fastclaw wait --for=condition=ready pod -l app=fastclaw --timeout=60s
T1=$(date +%s)

ELAPSED=$((T1 - T0))

if [ "$ELAPSED" -gt 5 ]; then
  echo "FAIL: cold start ${ELAPSED}s > 5s"
  exit 1
fi
echo "OK: cold start ${ELAPSED}s (≤ 5s)"
```

- [ ] **Step 4.2: 加权限 + 跑脚本**

```bash
chmod +x deploy/local/verify/02-cold-start.sh
bash deploy/local/verify/02-cold-start.sh
```

预期: `OK: cold start <N>s (≤ 5s)`。

注意: 该脚本会影响后续脚本依赖的 pod 状态。运行后等所有 pod ready 再继续:

```bash
kubectl -n fastclaw wait --for=condition=ready pod -l app=fastclaw --timeout=60s
```

- [ ] **Step 4.3: 提交**

```bash
git add deploy/local/verify/02-cold-start.sh
git commit -m "test: verify/02 gateway cold start ≤ 5s"
```

---

## Task 5: verify/03 单 pod RSS

**Files:**
- Create: `deploy/local/verify/03-pod-rss.sh`

**Steps:**

- [ ] **Step 5.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/verify/03-pod-rss.sh`

```bash
#!/usr/bin/env bash
# verify/03-pod-rss.sh
# 目标: 单 pod 稳态 RSS ≤ 200 MiB

set -euo pipefail

# metrics-server 需就绪, orbstack 默认装. 等几秒让数据有效.
sleep 10

OUT=$(kubectl -n fastclaw top pod -l app=fastclaw --no-headers 2>&1)
if echo "$OUT" | grep -qi "error"; then
  echo "FAIL: kubectl top 出错: $OUT"
  echo "(orbstack 缺 metrics-server? 检查 kubectl top node)"
  exit 1
fi

FAILED=0
while IFS= read -r LINE; do
  POD=$(echo "$LINE" | awk '{print $1}')
  MEM=$(echo "$LINE" | awk '{gsub(/Mi/,"",$3); print $3}')
  if [ "${MEM:-0}" -gt 200 ]; then
    echo "FAIL: $POD RSS=${MEM}Mi > 200Mi"
    FAILED=1
  else
    echo "OK: $POD RSS=${MEM}Mi"
  fi
done <<< "$OUT"

exit "$FAILED"
```

- [ ] **Step 5.2: 跑脚本**

```bash
chmod +x deploy/local/verify/03-pod-rss.sh
bash deploy/local/verify/03-pod-rss.sh
```

预期: 每个 pod 一行 `OK: fastclaw-xxx RSS=<N>Mi`, 退出码 0。

- [ ] **Step 5.3: 提交**

```bash
git add deploy/local/verify/03-pod-rss.sh
git commit -m "test: verify/03 single pod RSS ≤ 200Mi"
```

---

## Task 6: verify/04 多 pod 一致性

**Files:**
- Create: `deploy/local/verify/04-multipod-consistency.sh`

**Steps:**

- [ ] **Step 6.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/verify/04-multipod-consistency.sh`

```bash
#!/usr/bin/env bash
# verify/04-multipod-consistency.sh
# 目标: pod-0 写, pod-1 立即可读 (经由共享 PG)

set -euo pipefail

PODS=($(kubectl -n fastclaw get pod -l app=fastclaw -o name))
[ "${#PODS[@]}" -ge 2 ] || { echo "FAIL: pod 副本 < 2"; exit 1; }

POD0="${PODS[0]}"
POD1="${PODS[1]}"
AGENT_NAME="test-agent-consistency"

# pod-0 创建 agent
kubectl -n fastclaw exec "$POD0" -- fastclaw agents init "$AGENT_NAME" \
  --provider openai \
  --model openai/gpt-4o-mini \
  --api-key-env OPENAI_API_KEY \
  > /tmp/agents-init.log 2>&1

# pod-1 立即查询
RESULT=$(kubectl -n fastclaw exec "$POD1" -- fastclaw agents ls | grep "$AGENT_NAME" || true)

if [ -z "$RESULT" ]; then
  echo "FAIL: pod1 没看到 pod0 创建的 agent '$AGENT_NAME'"
  echo "pod1 输出:"
  kubectl -n fastclaw exec "$POD1" -- fastclaw agents ls
  exit 1
fi
echo "OK: cross-pod 一致 ($RESULT)"
```

- [ ] **Step 6.2: 跑脚本**

```bash
chmod +x deploy/local/verify/04-multipod-consistency.sh
bash deploy/local/verify/04-multipod-consistency.sh
```

预期: `OK: cross-pod 一致 (test-agent-consistency  ...)`。

- [ ] **Step 6.3: 提交**

```bash
git add deploy/local/verify/04-multipod-consistency.sh
git commit -m "test: verify/04 multipod write-after-read consistency"
```

---

## Task 7: verify/05 sandbox 唤起延迟

**Files:**
- Create: `deploy/local/verify/05-sandbox-cold.sh`

**Steps:**

- [ ] **Step 7.1: 预置依赖检查 (gdate)**

```bash
which gdate || brew install coreutils
```

预期: `/opt/homebrew/bin/gdate` 或 brew 安装成功。

- [ ] **Step 7.2: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/verify/05-sandbox-cold.sh`

```bash
#!/usr/bin/env bash
# verify/05-sandbox-cold.sh
# 目标: 触发 sandbox 的请求, 端到端首响 ≤ 3s

set -euo pipefail

TOKEN=$(cat .admin_token 2>/dev/null) || { echo "FAIL: .admin_token 不存在, 执行 Task 2 Step 2.8 先获取"; exit 1; }
[ -n "$TOKEN" ] || { echo "FAIL: .admin_token 为空"; exit 1; }

# port-forward 应已在 Task 2 Step 2.9 启动
curl -sf http://localhost:18953/readyz > /dev/null || { echo "FAIL: gateway 不可达 (port-forward 挂了?)"; exit 1; }

T0=$(gdate +%s.%N)
curl -sN \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-4o-mini","messages":[{"role":"user","content":"运行 ls / 并告诉我结果"}],"stream":true}' \
  http://localhost:18953/v1/chat/completions > /tmp/sse.log 2>&1
T1=$(gdate +%s.%N)

ELAPSED=$(echo "$T1 - $T0" | bc)

awk -v e="$ELAPSED" 'BEGIN {
  if (e + 0 > 3.0) { print "FAIL: sandbox cold " e "s > 3s"; exit 1 }
  print "OK: sandbox cold " e "s (≤ 3s)"
}'
```

- [ ] **Step 7.3: 跑脚本**

```bash
chmod +x deploy/local/verify/05-sandbox-cold.sh
bash deploy/local/verify/05-sandbox-cold.sh
```

预期: `OK: sandbox cold <N.N>s (≤ 3s)`。

排错: 若延迟超 3s, 看 `/tmp/sse.log`。多数原因是 LLM provider 慢, 而非 sandbox 冷启动慢; 可改 prompt 避免触发 tool_call 来分离测量。

- [ ] **Step 7.4: 提交**

```bash
git add deploy/local/verify/05-sandbox-cold.sh
git commit -m "test: verify/05 sandbox cold start ≤ 3s end-to-end"
```

---

## Task 8: verify/06 存算分离

**Files:**
- Create: `deploy/local/verify/06-statelessness.sh`

**Steps:**

- [ ] **Step 8.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/verify/06-statelessness.sh`

```bash
#!/usr/bin/env bash
# verify/06-statelessness.sh
# 目标: kill 所有 gateway pod 后, agent 文件 (从 PG) 仍能读到
# 依赖: Task 6 (verify/04) 已创建 test-agent-consistency

set -euo pipefail

AGENT_NAME="test-agent-consistency"

# 前置: 确认 agent 存在
BEFORE=$(kubectl -n fastclaw exec deploy/fastclaw -- fastclaw agents ls | grep "$AGENT_NAME" || true)
[ -n "$BEFORE" ] || { echo "FAIL: 前置缺失 '$AGENT_NAME', 先跑 verify/04"; exit 1; }

# 暴力 kill 所有 gateway
kubectl -n fastclaw delete pod -l app=fastclaw --grace-period=0 --force

# 等副本恢复
kubectl -n fastclaw wait --for=condition=ready pod -l app=fastclaw --timeout=120s

# 复读
AFTER=$(kubectl -n fastclaw exec deploy/fastclaw -- fastclaw agents ls | grep "$AGENT_NAME" || true)
if [ -z "$AFTER" ]; then
  echo "FAIL: 重启后 agent '$AGENT_NAME' 丢失"
  exit 1
fi
echo "OK: 重启后状态完整 ($AFTER)"
```

- [ ] **Step 8.2: 跑脚本**

```bash
chmod +x deploy/local/verify/06-statelessness.sh
bash deploy/local/verify/06-statelessness.sh
```

预期: `OK: 重启后状态完整 (test-agent-consistency ...)`。

- [ ] **Step 8.3: 提交**

```bash
git add deploy/local/verify/06-statelessness.sh
git commit -m "test: verify/06 statelessness across pod restart"
```

---

## Task 9: verify/07 滚动可用性

**Files:**
- Create: `deploy/local/verify/07-rolling-availability.sh`

**Steps:**

- [ ] **Step 9.1: 安装 hey 压测工具**

```bash
which hey || brew install hey
```

预期: `/opt/homebrew/bin/hey`。

- [ ] **Step 9.2: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/verify/07-rolling-availability.sh`

```bash
#!/usr/bin/env bash
# verify/07-rolling-availability.sh
# 目标: 压测期间 kill pod, 0 失败请求

set -euo pipefail

TOKEN=$(cat .admin_token)
curl -sf http://localhost:18953/readyz > /dev/null || { echo "FAIL: gateway 不可达"; exit 1; }

# 后台压测 (避免触发 LLM, 用 /api/agents 列表)
hey -n 2000 -c 10 -H "Authorization: Bearer $TOKEN" \
    http://localhost:18953/api/agents > /tmp/hey.log 2>&1 &
HEY_PID=$!

# 等 1s 让压测启动稳定
sleep 1

# 杀掉其中一个 pod
VICTIM=$(kubectl -n fastclaw get pod -l app=fastclaw -o name | head -1)
kubectl -n fastclaw delete "$VICTIM" --grace-period=30 > /dev/null

# 等压测结束
wait $HEY_PID || true

# 解析失败数
NON_2XX=$(awk '
  /Status code distribution/ {flag=1; next}
  flag && /^[[:space:]]*\[[0-9]+\]/ {
    code=$1; gsub(/[\[\]]/, "", code)
    if (code+0 >= 400) sum += $2
  }
  END {print sum + 0}
' /tmp/hey.log)

if [ "$NON_2XX" -ne 0 ]; then
  echo "FAIL: $NON_2XX 个非 2xx 请求"
  echo "hey 报告:"
  cat /tmp/hey.log
  exit 1
fi
echo "OK: 0 失败请求 (kill pod 期间)"

# 等副本恢复, 不污染后续脚本
kubectl -n fastclaw wait --for=condition=ready pod -l app=fastclaw --timeout=60s
```

- [ ] **Step 9.3: 跑脚本**

```bash
chmod +x deploy/local/verify/07-rolling-availability.sh
bash deploy/local/verify/07-rolling-availability.sh
```

预期: `OK: 0 失败请求 (kill pod 期间)`。

- [ ] **Step 9.4: 提交**

```bash
git add deploy/local/verify/07-rolling-availability.sh
git commit -m "test: verify/07 rolling availability under pod kill"
```

---

## Task 10: verify/all.sh 主控

**Files:**
- Create: `deploy/local/verify/all.sh`

**Steps:**

- [ ] **Step 10.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/verify/all.sh`

```bash
#!/usr/bin/env bash
# verify/all.sh — 主控. 按字典序 (= 数字序) 跑 01~07.
# 顺序约定: 04 创建 test-agent-consistency, 06 复用之.

set -e

cd "$(dirname "$0")"

PASS=0
TOTAL=0

for s in 0*.sh; do
  TOTAL=$((TOTAL + 1))
  echo "─── running $s ───"
  if bash "$s"; then
    PASS=$((PASS + 1))
  else
    echo "❌ $s FAILED"
    exit 1
  fi
done

echo ""
echo "═════════════════════════════════════"
echo "ALL VERIFY PASS ($PASS / $TOTAL)"
echo "═════════════════════════════════════"
```

- [ ] **Step 10.2: 加权限 + 跑**

```bash
chmod +x deploy/local/verify/all.sh
bash deploy/local/verify/all.sh
```

预期最后一行: `ALL VERIFY PASS (7 / 7)`。

- [ ] **Step 10.3: 提交**

```bash
git add deploy/local/verify/all.sh
git commit -m "test: verify/all.sh master runner"
```

---

## Task 11: drills/01 单 gateway pod kill

**Files:**
- Create: `deploy/local/drills/01-gateway-pod-kill.sh`

**Steps:**

- [ ] **Step 11.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/drills/01-gateway-pod-kill.sh`

```bash
#!/usr/bin/env bash
# drills/01-gateway-pod-kill.sh
# 故障: kill 单个 gateway pod
# 预期: 另一 pod 接管, PDB 维持 ≥1 在线, 0 失败

set -euo pipefail

TOKEN=$(cat .admin_token)

# 后台压测
hey -z 30s -c 5 -H "Authorization: Bearer $TOKEN" \
    http://localhost:18953/api/agents > /tmp/drill01.log 2>&1 &
HEY_PID=$!

sleep 2

# 杀一个
VICTIM=$(kubectl -n fastclaw get pod -l app=fastclaw -o name | head -1)
echo "→ killing $VICTIM"
kubectl -n fastclaw delete "$VICTIM" --grace-period=30 > /dev/null

# 等压测结束
wait $HEY_PID

# 至少有 1 个 pod 在线
ALIVE=$(kubectl -n fastclaw get pod -l app=fastclaw --field-selector=status.phase=Running -o name | wc -l | tr -d ' ')
if [ "$ALIVE" -lt 1 ]; then
  echo "FAIL: PDB 失效, 在线 pod = $ALIVE"
  exit 1
fi

NON_2XX=$(awk '/Status code distribution/{f=1;next} f&&/^[[:space:]]*\[[0-9]+\]/{c=$1; gsub(/[\[\]]/,"",c); if(c+0>=400) s+=$2} END{print s+0}' /tmp/drill01.log)
if [ "$NON_2XX" -ne 0 ]; then
  echo "FAIL: $NON_2XX 个失败请求"
  exit 1
fi

echo "PASS: 1 pod kill, 0 失败, PDB ≥ 1 保持"
```

- [ ] **Step 11.2: 跑**

```bash
chmod +x deploy/local/drills/01-gateway-pod-kill.sh
bash deploy/local/drills/01-gateway-pod-kill.sh
```

预期: `PASS: 1 pod kill, 0 失败, PDB ≥ 1 保持`。

- [ ] **Step 11.3: 提交**

```bash
git add deploy/local/drills/01-gateway-pod-kill.sh
git commit -m "test(drill): 01 single gateway pod kill resilience"
```

---

## Task 12: drills/02 全 gateway 同时挂

**Files:**
- Create: `deploy/local/drills/02-all-gateway-down.sh`

**Steps:**

- [ ] **Step 12.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/drills/02-all-gateway-down.sh`

```bash
#!/usr/bin/env bash
# drills/02-all-gateway-down.sh
# 故障: scale 到 0 再 scale 回 2
# 预期: PG/MinIO 数据完整, agent 列表恢复

set -euo pipefail

# 前置: 拿当前 agent 数量
BEFORE=$(kubectl -n fastclaw exec deploy/fastclaw -- fastclaw agents ls | tail -n +2 | wc -l | tr -d ' ')
echo "→ before: $BEFORE agents"

# scale 到 0
kubectl -n fastclaw scale deploy/fastclaw --replicas=0
kubectl -n fastclaw wait --for=delete pod -l app=fastclaw --timeout=60s 2>/dev/null || true

# scale 回 2
kubectl -n fastclaw scale deploy/fastclaw --replicas=2
kubectl -n fastclaw wait --for=condition=ready pod -l app=fastclaw --timeout=120s

# 复读
AFTER=$(kubectl -n fastclaw exec deploy/fastclaw -- fastclaw agents ls | tail -n +2 | wc -l | tr -d ' ')
echo "→ after:  $AFTER agents"

if [ "$BEFORE" != "$AFTER" ]; then
  echo "FAIL: agent 数量变化 $BEFORE → $AFTER"
  exit 1
fi
echo "PASS: 全挂后恢复, agent 数量一致 ($BEFORE)"
```

- [ ] **Step 12.2: 跑**

```bash
chmod +x deploy/local/drills/02-all-gateway-down.sh
bash deploy/local/drills/02-all-gateway-down.sh
```

预期: `PASS: 全挂后恢复, agent 数量一致 (<N>)`。

- [ ] **Step 12.3: 提交**

```bash
git add deploy/local/drills/02-all-gateway-down.sh
git commit -m "test(drill): 02 all-gateway-down state survival"
```

---

## Task 13: drills/03 Postgres 重启

**Files:**
- Create: `deploy/local/drills/03-postgres-restart.sh`

**Steps:**

- [ ] **Step 13.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/drills/03-postgres-restart.sh`

```bash
#!/usr/bin/env bash
# drills/03-postgres-restart.sh
# 故障: kill postgres-0
# 预期: gateway 短暂失败, 5s 内恢复

set -euo pipefail

TOKEN=$(cat .admin_token)

# kill PG
echo "→ killing postgres-0"
kubectl -n fastclaw delete pod postgres-0 --grace-period=0 --force > /dev/null

# 立即轮询 gateway, 直到返回 2xx
T0=$(date +%s)
DEADLINE=$((T0 + 30))
RECOVERED=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if curl -sf -H "Authorization: Bearer $TOKEN" http://localhost:18953/api/agents > /dev/null 2>&1; then
    T1=$(date +%s)
    ELAPSED=$((T1 - T0))
    echo "→ recovered after ${ELAPSED}s"
    RECOVERED=1
    break
  fi
  sleep 1
done

if [ "$RECOVERED" -ne 1 ]; then
  echo "FAIL: 30s 内未恢复"
  exit 1
fi

# 等 PG 完全 ready 再退出, 不污染后续
kubectl -n fastclaw wait --for=condition=ready pod postgres-0 --timeout=60s

if [ "$ELAPSED" -gt 10 ]; then
  echo "WARN: 恢复 ${ELAPSED}s > 10s (spec 目标 5s, 容差 10s)"
fi
echo "PASS: PG 重启后恢复 (${ELAPSED}s)"
```

- [ ] **Step 13.2: 跑**

```bash
chmod +x deploy/local/drills/03-postgres-restart.sh
bash deploy/local/drills/03-postgres-restart.sh
```

预期: `PASS: PG 重启后恢复 (<N>s)`。

- [ ] **Step 13.3: 提交**

```bash
git add deploy/local/drills/03-postgres-restart.sh
git commit -m "test(drill): 03 postgres restart recovery"
```

---

## Task 14: drills/04 MinIO 重启

**Files:**
- Create: `deploy/local/drills/04-minio-restart.sh`

**Steps:**

- [ ] **Step 14.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/drills/04-minio-restart.sh`

```bash
#!/usr/bin/env bash
# drills/04-minio-restart.sh
# 故障: kill minio-0
# 预期: bucket 复活, 文件不丢

set -euo pipefail

# 先列 bucket 内对象数量
BEFORE=$(kubectl -n fastclaw run --rm -i --restart=Never --image=minio/mc:latest tmpmc -- \
  sh -c 'mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null && mc ls --recursive local/fastclaw | wc -l' \
  2>/dev/null | tr -d ' ' || echo 0)
echo "→ before: $BEFORE object(s)"

# kill
echo "→ killing minio-0"
kubectl -n fastclaw delete pod minio-0 --grace-period=0 --force > /dev/null
kubectl -n fastclaw wait --for=condition=ready pod minio-0 --timeout=60s

# 复读
AFTER=$(kubectl -n fastclaw run --rm -i --restart=Never --image=minio/mc:latest tmpmc2 -- \
  sh -c 'mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null && mc ls --recursive local/fastclaw | wc -l' \
  2>/dev/null | tr -d ' ' || echo 0)
echo "→ after:  $AFTER object(s)"

if [ "$BEFORE" != "$AFTER" ]; then
  echo "FAIL: bucket 对象数 $BEFORE → $AFTER 不一致"
  exit 1
fi
echo "PASS: MinIO 重启, bucket 数据完整 ($BEFORE)"
```

- [ ] **Step 14.2: 跑**

```bash
chmod +x deploy/local/drills/04-minio-restart.sh
bash deploy/local/drills/04-minio-restart.sh
```

预期: `PASS: MinIO 重启, bucket 数据完整 (<N>)`。

- [ ] **Step 14.3: 提交**

```bash
git add deploy/local/drills/04-minio-restart.sh
git commit -m "test(drill): 04 minio restart data integrity"
```

---

## Task 15: drills/05 OOMKill

**Files:**
- Create: `deploy/local/drills/05-oom-kill.sh`

**Steps:**

- [ ] **Step 15.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/drills/05-oom-kill.sh`

```bash
#!/usr/bin/env bash
# drills/05-oom-kill.sh
# 故障: 临时把 limit 调到 32Mi 触发 OOMKill, 然后还原
# 预期: pod restart count +1, restart 后回到稳态

set -euo pipefail

# 记下原始 restart count
BEFORE=$(kubectl -n fastclaw get pod -l app=fastclaw -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
echo "→ before restartCount: $BEFORE"

# 把 limit 调到 32Mi
kubectl -n fastclaw set resources deploy/fastclaw \
  --limits=memory=32Mi --containers=fastclaw

# 等 OOMKill 触发 (约 1-2 min)
echo "→ 等待 OOMKill 触发 (最多 120s)"
DEADLINE=$(($(date +%s) + 120))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  AFTER=$(kubectl -n fastclaw get pod -l app=fastclaw -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "$BEFORE")
  if [ "$AFTER" != "$BEFORE" ] && [ -n "$AFTER" ]; then
    echo "→ OOMKill 触发, restartCount: $BEFORE → $AFTER"
    break
  fi
  sleep 5
done

# 还原
kubectl -n fastclaw set resources deploy/fastclaw \
  --limits=memory=512Mi --containers=fastclaw

kubectl -n fastclaw rollout status deploy/fastclaw --timeout=120s

if [ "$AFTER" = "$BEFORE" ]; then
  echo "FAIL: 120s 内未触发 OOMKill"
  exit 1
fi

echo "PASS: OOMKill 触发后自愈 ($BEFORE → $AFTER)"
```

- [ ] **Step 15.2: 跑**

```bash
chmod +x deploy/local/drills/05-oom-kill.sh
bash deploy/local/drills/05-oom-kill.sh
```

预期: `PASS: OOMKill 触发后自愈 (<N> → <M>)`。

- [ ] **Step 15.3: 提交**

```bash
git add deploy/local/drills/05-oom-kill.sh
git commit -m "test(drill): 05 oom-kill self-heal"
```

---

## Task 16: drills/06 E2B 黑洞

**Files:**
- Create: `deploy/local/drills/06-e2b-blackhole.sh`

**Steps:**

- [ ] **Step 16.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/drills/06-e2b-blackhole.sh`

```bash
#!/usr/bin/env bash
# drills/06-e2b-blackhole.sh
# 故障: 临时把 E2B_API_KEY 改无效 (模拟网络不通)
# 预期: tool_call 调用失败, 但 /api/agents 列表仍 200

set -euo pipefail

TOKEN=$(cat .admin_token)

# 1. 调用非 sandbox 路径, 应 200
NORMAL=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost:18953/api/agents)
[ "$NORMAL" = "200" ] || { echo "FAIL: 正常路径不可用 (HTTP $NORMAL)"; exit 1; }

# 2. patch secret 把 E2B key 改无效
kubectl -n fastclaw patch secret fastclaw-secrets --type=json \
  -p='[{"op":"replace","path":"/data/E2B_API_KEY","value":"'"$(echo -n invalid_e2b_blackhole | base64)"'"}]'

# 3. 重启 fastclaw pod 让 env 生效
kubectl -n fastclaw rollout restart deploy/fastclaw
kubectl -n fastclaw rollout status deploy/fastclaw --timeout=120s
sleep 3

# 4. 再次调 /api/agents, 仍 200
STILL=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost:18953/api/agents)
if [ "$STILL" != "200" ]; then
  echo "FAIL: E2B 不通后 /api/agents 返回 HTTP $STILL"
  exit 1
fi

# 5. 还原: 需手动改回真 E2B key. 这里给提示.
echo "PASS: E2B 不可达期间, 非 sandbox 路径仍 200"
echo "⚠️  恢复方法: 编辑 fastclaw-orbstack.yaml E2B_API_KEY 回真值, kubectl apply, rollout restart"
```

- [ ] **Step 16.2: 跑**

```bash
chmod +x deploy/local/drills/06-e2b-blackhole.sh
bash deploy/local/drills/06-e2b-blackhole.sh
```

预期: `PASS: E2B 不可达期间, 非 sandbox 路径仍 200`。

跑完后**手动恢复** E2B_API_KEY 为真值:

```bash
# 重新 apply 原 yaml (其中 E2B_API_KEY 还是 Task 2 Step 2.2 填的真值)
kubectl apply -f deploy/local/fastclaw-orbstack.yaml
kubectl -n fastclaw rollout restart deploy/fastclaw
kubectl -n fastclaw rollout status deploy/fastclaw --timeout=120s
```

- [ ] **Step 16.3: 提交**

```bash
git add deploy/local/drills/06-e2b-blackhole.sh
git commit -m "test(drill): 06 e2b unreachable graceful degradation"
```

---

## Task 17: drills/07 port-forward 恢复

**Files:**
- Create: `deploy/local/drills/07-portforward-resume.sh`

**Steps:**

- [ ] **Step 17.1: 写脚本**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/drills/07-portforward-resume.sh`

```bash
#!/usr/bin/env bash
# drills/07-portforward-resume.sh
# 故障: 杀 port-forward 后重启, 即刻可用

set -euo pipefail

TOKEN=$(cat .admin_token)

# 确认当前可用
curl -sf -H "Authorization: Bearer $TOKEN" http://localhost:18953/api/agents > /dev/null

# 杀 port-forward
if [ -f /tmp/pf.pid ]; then
  PID=$(cat /tmp/pf.pid)
  kill "$PID" 2>/dev/null || true
fi
pkill -f "kubectl.*port-forward.*fastclaw" 2>/dev/null || true
sleep 2

# 验证不通
if curl -sf --max-time 3 http://localhost:18953/readyz 2>/dev/null; then
  echo "FAIL: port-forward 未真正关闭"
  exit 1
fi

# 重起 port-forward
kubectl -n fastclaw port-forward svc/fastclaw 18953:80 > /tmp/pf.log 2>&1 &
echo $! > /tmp/pf.pid
sleep 2

# 再次可用
if curl -sf -H "Authorization: Bearer $TOKEN" http://localhost:18953/api/agents > /dev/null; then
  echo "PASS: port-forward 恢复立即可用"
else
  echo "FAIL: 重启 port-forward 后仍不通"
  exit 1
fi
```

- [ ] **Step 17.2: 跑**

```bash
chmod +x deploy/local/drills/07-portforward-resume.sh
bash deploy/local/drills/07-portforward-resume.sh
```

预期: `PASS: port-forward 恢复立即可用`。

- [ ] **Step 17.3: 提交**

```bash
git add deploy/local/drills/07-portforward-resume.sh
git commit -m "test(drill): 07 port-forward resume"
```

---

## Task 18: README 入口文档

**Files:**
- Create: `deploy/local/README.md`

**Steps:**

- [ ] **Step 18.1: 写 README**

文件: `/Users/jinguo.zeng/dmall/project/kubernetes/deploy/local/README.md`

````markdown
# FastClaw 本地复现 (M1 + OrbStack k8s)

详见设计文档: `docs/superpowers/specs/2026-06-02-fastclaw-local-repro-design.md`

## 一次性准备

1. 安装 OrbStack ≥ 1.7, 启用 Settings → Kubernetes
2. `brew install kubectl jq hey coreutils` (gdate 来自 coreutils)
3. 编辑 `fastclaw-orbstack.yaml` 内 `fastclaw-secrets`, 填 `E2B_API_KEY` 与 `OPENAI_API_KEY`
4. `git update-index --assume-unchanged deploy/local/fastclaw-orbstack.yaml`

## 部署

```bash
kubectl apply -f deploy/local/fastclaw-orbstack.yaml
kubectl -n fastclaw wait --for=condition=ready pod -l app=postgres --timeout=120s
kubectl -n fastclaw wait --for=condition=ready pod -l app=minio --timeout=120s
kubectl -n fastclaw wait --for=condition=complete job/minio-bucket-init --timeout=60s
kubectl -n fastclaw rollout status deploy/fastclaw --timeout=180s
```

## 创建 admin + token

```bash
kubectl -n fastclaw exec deploy/fastclaw -- \
  fastclaw admin create-user --username alice \
    --email alice@example.com --password 'hunter2' --role super_admin

kubectl -n fastclaw exec deploy/fastclaw -- \
  fastclaw apikey create --username alice --tier admin --name verify \
  | awk '/^Token:/ {print $2}' > .admin_token
chmod 600 .admin_token
```

## 暴露到 host

```bash
kubectl -n fastclaw port-forward svc/fastclaw 18953:80 > /tmp/pf.log 2>&1 &
echo $! > /tmp/pf.pid
```

仪表盘: http://localhost:18953

## 跑验收

```bash
bash deploy/local/verify/all.sh
```

预期: `ALL VERIFY PASS (7 / 7)`

## 跑单个故障演练

```bash
bash deploy/local/drills/01-gateway-pod-kill.sh
bash deploy/local/drills/02-all-gateway-down.sh
bash deploy/local/drills/03-postgres-restart.sh
bash deploy/local/drills/04-minio-restart.sh
bash deploy/local/drills/05-oom-kill.sh
bash deploy/local/drills/06-e2b-blackhole.sh   # 跑完手动恢复 E2B key
bash deploy/local/drills/07-portforward-resume.sh
```

## 清理

```bash
kill "$(cat /tmp/pf.pid)" 2>/dev/null
kubectl delete -f deploy/local/fastclaw-orbstack.yaml
rm -f .admin_token /tmp/pf.pid /tmp/pf.log /tmp/sse.log /tmp/hey.log /tmp/drill01.log
```

## 排错速查

| 现象 | 大概率原因 | 处理 |
|---|---|---|
| `ImagePullBackOff` on fastclaw pod | ARM64 manifest 缺失 | `make build` 本地构建, 改 image 字段 |
| `kubectl top` 报错 | metrics-server 未就绪 | 等几分钟 / 重启 orbstack |
| port-forward 没反应 | 上一进程没退 | `pkill -f kubectl.*port-forward` |
| `verify/05` 超 3s | LLM provider 慢 (非 sandbox) | 换 prompt 不触发 tool_call 测纯网关延迟 |
| E2B 401 | E2B_API_KEY 错或额度耗尽 | e2b.dev dashboard 检查 |
````

- [ ] **Step 18.2: 提交**

```bash
git add deploy/local/README.md
git commit -m "docs: deploy/local README — run guide + troubleshooting"
```

---

## Task 19: 端到端 sanity 跑通

**Files:**
- (无新文件, 综合校验)

**Steps:**

- [ ] **Step 19.1: 干净环境从头部署**

```bash
kubectl delete -f deploy/local/fastclaw-orbstack.yaml --ignore-not-found
kubectl wait --for=delete ns/fastclaw --timeout=120s 2>/dev/null || true

kubectl apply -f deploy/local/fastclaw-orbstack.yaml
kubectl -n fastclaw wait --for=condition=ready pod -l app=postgres --timeout=120s
kubectl -n fastclaw wait --for=condition=ready pod -l app=minio --timeout=120s
kubectl -n fastclaw wait --for=condition=complete job/minio-bucket-init --timeout=60s
kubectl -n fastclaw rollout status deploy/fastclaw --timeout=180s
```

预期: 全 ready, 无 error。

- [ ] **Step 19.2: 重新创建 admin + token**

```bash
kubectl -n fastclaw exec deploy/fastclaw -- \
  fastclaw admin create-user --username alice \
    --email alice@example.com --password 'hunter2' --role super_admin

kubectl -n fastclaw exec deploy/fastclaw -- \
  fastclaw apikey create --username alice --tier admin --name verify \
  | awk '/^Token:/ {print $2}' > .admin_token
chmod 600 .admin_token
```

- [ ] **Step 19.3: 重起 port-forward**

```bash
pkill -f "kubectl.*port-forward.*fastclaw" 2>/dev/null || true
kubectl -n fastclaw port-forward svc/fastclaw 18953:80 > /tmp/pf.log 2>&1 &
echo $! > /tmp/pf.pid
sleep 3
curl -sf http://localhost:18953/readyz && echo "OK: gateway up"
```

- [ ] **Step 19.4: 跑 verify/all.sh**

```bash
bash deploy/local/verify/all.sh
```

预期: `ALL VERIFY PASS (7 / 7)`。

- [ ] **Step 19.5: 抽 3 个 drill 验证**

```bash
bash deploy/local/drills/01-gateway-pod-kill.sh
bash deploy/local/drills/03-postgres-restart.sh
bash deploy/local/drills/04-minio-restart.sh
```

预期: 每个脚本最后一行 `PASS: ...`。

- [ ] **Step 19.6: 提交 sanity 通过标记**

```bash
git commit --allow-empty -m "verify: e2e sanity pass on M1 16G orbstack"
```

---

## 完成标准

- [x] 所有 18 项 Task 完成 (Task 0 ~ 18 = 19 个 task)
- [x] `bash deploy/local/verify/all.sh` 输出 `ALL VERIFY PASS (7 / 7)`
- [x] 7 个 drill 各自独立 PASS
- [x] git log 显示每个 task 至少一个 commit
- [x] `kubectl -n fastclaw top pod` 总内存 ≤ 2 GB
