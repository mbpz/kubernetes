# 09 — 迁生产 (orbstack → EKS / GKE / AKS)

## 场景

orbstack 单节点开发用, 不适合生产. 迁到托管 k8s (EKS / GKE / AKS / 自建 kubeadm).

## orbstack vs 生产 k8s 差异

| 项 | orbstack | 生产 |
|---|---|---|
| 节点 | 1 (Mac 本地容器) | 3+ (HA) |
| 网络 | 本机路由 | VPC + CNI (Calico/Cilium) |
| 存储 | hostPath | 云盘 (EBS/PD/Disk) |
| 镜像拉取 | `imagePullPolicy: Never` (本地) | `IfNotPresent` / `Always`, 远端 registry |
| metrics-server | 需手动 apply | 大多集群预装 |
| TLS | kubelet 自签, `--kubelet-insecure-tls` | 真实 CA, 不需 insecure flag |
| Ingress | 无 | 需 Ingress Controller + DNS |
| 备份 | 本地目录 | 异地 S3 |
| 监控 | kubectl top | Prometheus + Grafana |

## 迁移步骤 (checklist)

### 1. 准备镜像 registry

```bash
# 1a. 选 registry (ECR / GCR / ACR / GHCR / 自建 Harbor)
export REGISTRY=ghcr.io/your-org
export IMAGE=$REGISTRY/fastclaw:v1.2.3

# 1b. 登录 + tag
docker login $REGISTRY
docker tag fastclaw:local $IMAGE
docker push $IMAGE

# 1c. (推荐) 推 SHA 唯一 tag, 不用 mutable tag
SHA=$(docker inspect --format='{{index .RepoDigests 0}}' fastclaw:local | cut -d@ -f2)
docker tag fastclaw:local $REGISTRY/fastclaw@sha256:$SHA
docker push $REGISTRY/fastclaw@sha256:$SHA
```

### 2. 改造 manifest

把 `deploy/local/fastclaw-orbstack.yaml` 复制到 `deploy/prod/fastclaw-prod.yaml`, 改:

```yaml
# 改 1: 镜像 (用上一步 push 的)
image: ghcr.io/your-org/fastclaw:v1.2.3
imagePullPolicy: IfNotPresent

# 改 2: postgres / minio 用云服务 (推荐) 或托管 operator
# 推荐: AWS RDS Postgres + S3 (或 GCS / Azure Blob)
# 不推荐: 集群内自管 postgres (HA / 备份麻烦)

# 改 3: 资源 limit 调到生产值
resources:
  requests: { cpu: "500m", memory: "512Mi" }
  limits:   { cpu: "2",    memory: "1Gi" }

# 改 4: HPA 上限抬
maxReplicas: 20

# 改 5: PDB 用 minAvailable + maxUnavailable 组合
spec:
  minAvailable: 2
  # 或
  maxUnavailable: 1

# 改 6: 加 Ingress + TLS
# (见下一步)

# 改 7: 加 NetworkPolicy 限制 ns 间通信
# (推荐) 默认 deny, 只放行 fastclaw <-> postgres/minio
```

### 3. Ingress + TLS

```yaml
# 单独的 ingress.yaml, 配 cert-manager + Let's Encrypt
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fastclaw
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx  # 或 alb / traefik
  tls:
    - hosts: [fastclaw.example.com]
      secretName: fastclaw-tls
  rules:
    - host: fastclaw.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: fastclaw
                port: { number: 80 }
```

### 4. 外部化密钥 (强烈推荐)

```bash
# 用 External Secrets Operator + AWS Secrets Manager
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace

# SecretStore 配置 (例: AWS)
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata: { name: aws-sm, namespace: fastclaw }
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef: { name: external-secrets-sa }
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: fastclaw-secrets, namespace: fastclaw }
spec:
  secretStoreRef: { name: aws-sm }
  target: { name: fastclaw-secrets }
  data:
    - secretKey: STORAGE_DSN
      remoteRef: { key: fastclaw/prod/dsn }
    - secretKey: OPENAI_API_KEY  # (如需)
      remoteRef: { key: fastclaw/prod/openai }
    - secretKey: E2B_API_KEY
      remoteRef: { key: fastclaw/prod/e2b }
```

### 5. 监控 + 日志

```bash
# 装 kube-prometheus-stack
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace

# 装 Loki (日志聚合)
helm install loki grafana/loki-stack -n logging --create-namespace
```

Grafana 仪表盘:
- fastclaw pod CPU / mem / RSS (PromQL: `container_memory_rss`)
- request rate / latency (需要 fastclaw 暴露 /metrics, 暂无, 见 [扩展点](#扩展点))
- PG 连接数 / 慢查询 (postgres_exporter)
- minio 容量 / 请求率 (minio 自带 /minio/v2/metrics/cluster)

### 6. CI/CD 流水线

```yaml
# 简化版 .github/workflows/deploy.yml
name: deploy
on: { push: { branches: [main] } }
jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: |
          docker build -t $REGISTRY/fastclaw:${{ github.sha }} .
          docker push $REGISTRY/fastclaw:${{ github.sha }}
      - name: Deploy
        uses: azure/setup-kubectl@v4
        with: { version: '1.30' }
      - name: Apply
        run: |
          echo "${{ secrets.KUBECONFIG }}" > /tmp/kc
          kubectl --kubeconfig=/tmp/kc set image deploy/fastclaw \
            fastclaw=$REGISTRY/fastclaw:${{ github.sha }}
          kubectl --kubeconfig=/tmp/kc rollout status deploy/fastclaw
```

### 7. 切流量

```bash
# 灰度: Ingress 加 canary annotation
# (nginx ingress 例子)
annotations:
  nginx.ingress.kubernetes.io/canary: "true"
  nginx.ingress.kubernetes.io/canary-weight: "10"  # 10% 流量

# 全切: 改 DNS A 记录
# (Cloudflare / Route53)

# 旧栈保留 24h 观察, 删
```

## 最小化清单 (LITE)

只做 1 + 2 + 3 + 4, 其他 (CI/CD 监控 多区) 后续补:
1. 镜像 push
2. 改 manifest (image + imagePullPolicy + resources)
3. Ingress + TLS
4. External Secrets (或暂时 kubectl create secret 手动)

## 不直接迁的

- `minio-bucket-init` Job: 生产用云存储, 不需要
- `metrics-server.yaml` 自定义版本: 大多集群已装
- `--kubelet-insecure-tls` flag: 删
- `imagePullPolicy: Never`: 删

## 扩展点 (迁生产后可加)

| 项 | 现状 | 生产 |
|---|---|---|
| postgres | 单实例 STS | RDS / Cloud SQL / Aurora |
| minio | 单实例 STS | S3 / GCS / OSS |
| minio 多用户 | 共享 root | per-tenant IAM user |
| HPA metric | CPU only | CPU + 自定义 (QPS / queue depth) |
| VPA | 无 | 自动调 request/limit |
| PDB | minAvailable: 1 | minAvailable: 2 (HA 副本) |
| NetworkPolicy | 无 | 默认 deny + 显式 allow |
| PodSecurityPolicy | 无 | 限制 (no privileged, runAsNonRoot) |
| ServiceAccount token | default | 单独 SA + IRSA / Workload Identity |
| Backup target | 本地 | S3 + 跨区 |
| Disaster recovery | 单集群 | 多 region + DNS failover |

## 回滚

迁生产后出问题:
1. Ingress 切回旧 orbstack IP (DNS TTL 注意)
2. 生产集群先 `kubectl scale deploy/fastclaw --replicas=0` 暂停
3. orbstack 仍跑老镜像, 数据未动

## 不推荐: 长期用 orbstack 做生产

| 限制 | 影响 |
|---|---|
| 单节点 | 无高可用, pod 调度无冗余 |
| Mac 本地存储 | 磁盘满 / 机器丢 = 数据丢 |
| 网络 | 仅本机回环, 外网访问靠 SSH tunnel |
| 资源 | 16G mem 顶 5-8 fastclaw pod |
| TLS | 自签, 浏览器警告 |

orbstack 是开发工具, 迁生产是必经步骤.
