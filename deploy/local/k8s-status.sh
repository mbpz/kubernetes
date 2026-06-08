#!/usr/bin/env bash
# k8s-status.sh — fastclaw 本地集群按 component 分组视图
# 依赖: 资源带 app.kubernetes.io/component 标签 (见 fastclaw-orbstack.yaml)

set -euo pipefail

NS="${NS:-fastclaw}"

hdr() { printf '\n=== %s ===\n' "$1"; }

hdr "Pods (component 列)"
kubectl -n "$NS" get pods \
  -L app.kubernetes.io/component \
  -o wide

hdr "Workloads (Deployment / StatefulSet / Job)"
kubectl -n "$NS" get deploy,sts,job \
  -L app.kubernetes.io/component -o wide

hdr "Services"
kubectl -n "$NS" get svc \
  -L app.kubernetes.io/component -o wide

hdr "Config / Secret"
kubectl -n "$NS" get cm,secret \
  -L app.kubernetes.io/component -o wide

hdr "HPA / PDB"
kubectl -n "$NS" get hpa,pdb \
  -L app.kubernetes.io/component -o wide

hdr "按 component 分组计数 (排除空)"
kubectl -n "$NS" get all \
  -L app.kubernetes.io/component --no-headers \
  | awk '{c=$(NF); if (c != "") print c}' | sort | uniq -c | sort -rn
