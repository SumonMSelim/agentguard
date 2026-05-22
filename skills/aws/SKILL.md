---
name: aws
tags: []
description: AWS best practices: IAM, secrets, networking, security, compute, IaC, ops. Use when building, reviewing, or modifying AWS resources.
license: MIT
---

# AWS

## Account structure
- Separate AWS accounts per environment (dev, staging, prod). Never share prod account
- AWS Organizations with SCPs for org-wide guardrails. Control Tower for multi-account setup
- Dedicated logging/security account. Ship CloudTrail, Config, and GuardDuty findings there
- SCPs: deny root usage, deny disabling CloudTrail/GuardDuty, enforce region restrictions

## IAM
- Least privilege. No wildcard actions/resources (`*`) in production
- No long-lived human access keys. Use IAM Identity Center, roles, temp credentials
- EC2/Lambda/ECS: instance profiles and execution roles. Never credentials in code or env vars
- EKS: IRSA (IAM Roles for Service Accounts) per pod. No node-level roles for app permissions
- Separate roles per service and environment. No shared roles across workloads
- Permission boundaries for delegated admin. Prevents privilege escalation via role creation
- MFA on all IAM users. Root locked — never used
- Rotate credentials. Audit via IAM Access Analyzer. Remove unused permissions

## Secrets
- Store in Secrets Manager or SSM Parameter Store (SecureString). Never in env vars, AMIs, images, Terraform state, or CloudFormation parameters (use SSM/Secrets Manager references)
- Auto-rotate via Secrets Manager rotation lambdas
- Reference by ARN in task definitions and Lambda config. Never pass values directly

## Networking
- VPC per environment. Public subnets: load balancers only. Private: compute and data
- Security groups: ingress from known sources only. No `0.0.0.0/0` except ALB port 443
- WAF in front of ALB and CloudFront for all public-facing workloads
- No EC2 public IPs unless required. Session Manager for all access — no SSH
- NACLs as secondary subnet-level layer
- VPC Flow Logs enabled. Ship to CloudWatch or S3
- PrivateLink for AWS service access where internet routing is avoidable

## Security
- CloudTrail in all regions. Logs to dedicated locked-down S3 bucket
- GuardDuty enabled. Security Hub enabled with baseline standard (AWS Foundational or CIS)
- Macie enabled on S3 buckets containing sensitive or PII data
- S3: block public access at account level. Explicit bucket policies only
- S3 versioning + MFA delete on sensitive buckets
- S3 lifecycle policies: transition to IA/Glacier, expire old versions. Unbounded storage compounds cost
- KMS: customer-managed keys (CMK) for sensitive data at rest. Audit key usage
- Config enabled with conformance packs for drift detection
- ECR: image scanning on push. Block deploy on critical/high CVEs

## Compute
- Lambda: least-privilege role, explicit timeout and memory, concurrency limits, dead-letter queues
- ECS: Fargate preferred. Task definitions: read-only root filesystem, no `privileged`, drop unused Linux capabilities
- EKS: Fargate or managed node groups. Pod security standards enforced. IRSA per workload
- Unmanaged EC2 nodes require justification
- Patch AMIs regularly via EC2 Image Builder. No unpatched instances
- Auto Scaling groups for all stateless compute. No single-instance production

## IaC
- All infrastructure as code (CDK, Terraform, CloudFormation). No manual console changes in production
- IaC in version control. Changes via PR, not direct apply
- Drift detection enabled in CloudFormation. Config rules catch out-of-band changes
- Stack/workspace separation per environment. No shared state across envs
- Secrets never in IaC source. Use SSM/Secrets Manager references at deploy time

## Ops
- Tag all resources: `env`, `team`, `service`, `owner`
- CloudWatch Logs retention set explicitly on all log groups. Default is indefinite — costs accumulate
- CloudWatch alarms on error rates, latency, queue depth
- X-Ray or ADOT (AWS Distro for OpenTelemetry) for distributed tracing
- Savings plans or reserved instances for predictable baseline
- Billing alarms and budgets set. Unexpected spikes require investigation
- Multi-AZ for all stateful services (RDS, ElastiCache). Single-AZ not production
- RDS: automated backups on, deletion protection on, encryption at rest on