---
name: kubernetes
tags: []
description: Kubernetes best practices: security, workloads, networking, config, operations, GitOps. Use when writing or reviewing K8s manifests and configurations.
license: MIT
---

# Kubernetes

## Pod security
- Never run as root. `runAsNonRoot: true`, `runAsUser` (non-zero) in `securityContext`
- `readOnlyRootFilesystem: true`. Mount writable volumes explicitly
- `allowPrivilegeEscalation: false`
- Drop all capabilities, re-add only what's needed: `capabilities: {drop: [ALL], add: [NET_BIND_SERVICE]}`
- No `hostPID`, `hostNetwork`, `hostIPC` without explicit system-level justification
- Pod Security Admission: `restricted` profile for all application workloads. `baseline` minimum for system workloads
- `automountServiceAccountToken: false` on pods that don't call the API server

## RBAC
- Least privilege. Separate `ServiceAccount` per workload. No default SA with cluster-level roles
- `Role`/`RoleBinding` over `ClusterRole`/`ClusterRoleBinding` unless cluster-scope is required
- Audit RBAC with `kubectl auth can-i --list` and `rakkess` or `rbac-tool`
- No `verbs: ["*"]` or `resources: ["*"]` in production roles

## Secrets
- Secrets in external store (Vault, AWS Secrets Manager, GCP Secret Manager). Sync via External Secrets Operator or Secrets Store CSI driver
- Never commit secrets to git. Plain Kubernetes `Secret` objects are base64 only — require etcd encryption at rest
- etcd encryption at rest enabled. etcd backed up on schedule (Velero or equivalent)

## Network policy
- Default-deny ingress and egress per namespace. Explicit allow rules per service
- NetworkPolicies enforced by CNI (Calico, Cilium, or equivalent). Verify CNI supports policy enforcement — not all do
- Cilium: use `CiliumNetworkPolicy` for L7 rules (HTTP, gRPC path/method filtering) where needed

## Workloads
- `Deployment` for stateless. `StatefulSet` for stateful with stable identity. `DaemonSet` for node-level agents
- `requests` and `limits` on every container. No unbounded CPU or memory
- CPU `limits` cause throttling — set conservatively or omit and rely on namespace `LimitRange`. Memory `limits` cause OOMKill — set with headroom
- `minReplicas` ≥ 2 for production. Single-replica = not HA
- Liveness probe: deadlock detection. Readiness probe: traffic gating. Startup probe: slow-starting containers. All three on every long-running container
- `terminationGracePeriodSeconds` set to cover max request duration + drain time. Default 30s is often too short
- `preStop: exec: sleep 5` (or equivalent) to allow load balancer to drain before SIGTERM
- `PodDisruptionBudget` on all production workloads. `minAvailable` > 0
- `topologySpreadConstraints` or `podAntiAffinity` to spread replicas across nodes and zones
- `HorizontalPodAutoscaler` on CPU/memory or custom metrics for stateless workloads
- KEDA for event-driven scaling (queue depth, Kafka lag, cron). Preferred over custom metrics pipelines
- `VerticalPodAutoscaler` in recommendation mode to right-size requests over time

## Images
- Never `latest` tag in manifests. Pin to digest or immutable tag
- `imagePullPolicy: Always` for mutable tags. `imagePullPolicy: IfNotPresent` for digest-pinned images
- Don't build images in-cluster. Build → scan → push → deploy (see Docker skill)

## Configuration
- `ConfigMap` for non-sensitive config. External secrets (not raw K8s `Secret`) for sensitive data
- No env-specific values baked into images. All config injected at runtime
- Namespaces per environment and team. `ResourceQuota` and `LimitRange` per namespace
- Labels on all resources: `app.kubernetes.io/name`, `app.kubernetes.io/version`, `app.kubernetes.io/component`, `env`, `team`

## Networking and ingress
- Ingress controller (NGINX, Traefik) for HTTP/HTTPS. Gateway API preferred for new clusters — more expressive than `Ingress`
- TLS termination at ingress. `cert-manager` for certificate lifecycle (Let's Encrypt or internal CA)
- Internal service-to-service: `ClusterIP`. External: `LoadBalancer` or ingress only. Never `NodePort` in production

## Policy enforcement
- OPA/Gatekeeper or Kyverno for org-wide policy as code: enforce labels, block `latest`, require probes, restrict privileges
- Policies in version control. Applied via GitOps, not ad-hoc
- Admission webhooks audited — failing-open webhooks can silently bypass policy

## Operations
- GitOps (ArgoCD or Flux) as single source of truth. No direct `kubectl apply` to production
- `kubectl diff` before any manual apply. Never apply blindly
- Helm or Kustomize for templating. No raw generated manifests in CI
- Cluster Autoscaler or Karpenter for node scaling. Right-size node pools per workload class (spot, on-demand, GPU)
- API server audit logs enabled. Ship to centralised logging
- Falco for runtime threat detection (unexpected syscalls, shell in container, sensitive file access)
- `kubectl rollout` for deploys. `maxUnavailable: 0`, `maxSurge: 1` for zero-downtime
- Upgrade clusters within N-2 of latest minor. Never run unsupported versions