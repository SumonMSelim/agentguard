---
name: gcp
tags: []
description: GCP best practices: IAM, secrets, networking, security, compute, IaC, ops. Use when building, reviewing, or modifying GCP resources.
license: MIT
---

# GCP

## Org and project structure
- Org > Folder > Project hierarchy. Folders per environment (dev, staging, prod) or team
- Separate projects per environment. Never share prod project with other envs
- Dedicated logging/security project. Ship Audit Logs, SCC findings, and VPC Flow Logs there
- Organization Policy constraints: restrict public IPs, enforce uniform bucket access, restrict allowed regions, deny SA key creation
- Billing account per team or BU. Budget alerts per project

## IAM
- Least privilege. Predefined roles before custom. Never primitive roles (`Owner`, `Editor`) in production
- Separate SA per workload and environment. No shared SAs across services
- No SA keys unless unavoidable. Use Workload Identity Federation for external systems, metadata server for GCP resources
- GKE: Workload Identity per pod. Never use default compute SA (`PROJECT_NUMBER-compute@developer.gserviceaccount.com`) — has broad Editor permissions
- Grant roles at resource level. Project-level only when scope is genuinely project-wide
- IAM Recommender enabled. Act on unused permission findings
- If keys exist: rotate regularly, audit usage, delete when unused. Never commit to git

## Secrets
- Store in Secret Manager. Never in env vars, container images, Terraform state, or deployment manifests
- GKE: access via Secret Manager API or mounted volumes (Workload Identity + CSI driver)
- Auto-rotation enabled where supported
- Reference by resource name in Cloud Run and GKE specs. Never inline values

## Networking
- VPC per environment. Shared VPC for multi-project setups
- Private Google Access on all subnets. No public IPs needed to reach GCP APIs
- Firewall rules: deny-all default, explicit allow only. No `0.0.0.0/0` except load balancer health checks
- Cloud NAT for outbound internet from private instances
- VPC Flow Logs on all subnets
- Private Service Connect for managed services (Cloud SQL, Memorystore, etc.)
- Cloud Armor on all internet-facing load balancers. WAF rules + DDoS protection enabled

## Security
- Security Command Center Standard or Premium enabled. Route findings to security project
- Cloud Audit Logs enabled for all services: Admin Activity and Data Access
- Binary Authorization on GKE — signed images from trusted registries only
- Artifact Registry: vulnerability scanning on push. Block deploy on critical/high CVEs
- Enable Access Transparency for visibility into Google admin actions
- Shielded VMs on all GCE instances. Confidential VMs for sensitive workloads
- GCS: uniform bucket-level access enforced. No legacy ACLs

## Compute
- Cloud Run for stateless workloads. GKE Autopilot for orchestrated. Raw GCE requires justification
- Cloud Run: set `--min-instances` to avoid cold starts on latency-sensitive services. Set `--concurrency` and `--cpu` explicitly. `--cpu-boost` on startup where needed
- GKE: separate node pools per workload profile (e.g. spot, high-memory, GPU)
- GKE: Pod Security Standards enforced. Workload Identity per pod. No default compute SA
- Cloud SQL: private IP only, IAM auth, automated backups, deletion protection on

## IaC
- All infrastructure as code (Terraform, Pulumi, or Deployment Manager). No manual console changes in production
- IaC in version control. Changes via PR, not direct apply
- Secrets never in IaC source. Use Secret Manager references at deploy time
- Separate Terraform state per environment. Remote state in GCS with versioning and locking

## Ops
- Label all resources: `env`, `team`, `service`, `owner`. Enforce with org policies
- Cloud Logging: set retention explicitly on all log buckets. Default retention incurs cost at scale
- Cloud Monitoring + Cloud Logging for all workloads. Alerting policies on error rates, latency, saturation
- Enable Error Reporting, Cloud Trace, and Cloud Profiler for full observability
- Multi-region or regional HA for all stateful services. Zonal = not production
- Committed Use Discounts for predictable baseline compute (GCE, Cloud SQL, GKE)