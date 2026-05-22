---
name: terraform
tags: []
description: Terraform best practices: state, security, modules, workflow, testing, tooling. Use when writing or reviewing Terraform code.
license: MIT
---

# Terraform

## State
- Remote state always. Local state for throwaway experiments only
- State backend with locking: S3 + DynamoDB, GCS, or Terraform Cloud/HCP
- Separate state files per environment (`dev`, `staging`, `prod`). Never share state across envs
- Encrypt state at rest. Versioning on state bucket enables rollback — never delete old versions without confirming they are not needed
- Never commit `.tfstate` or `.tfstate.backup` to git. Add to `.gitignore`
- `sensitive = true` on all outputs containing secrets, tokens, or credentials. Limits plaintext exposure in logs and state diffs

## Security
- Least privilege for the Terraform runner. Scope to exactly what it creates
- OIDC / Workload Identity for CI runners. No long-lived access keys
- Secrets never in `.tf` files or `terraform.tfvars` committed to git. Pass via `TF_VAR_*` env vars, Vault, or secret manager at plan/apply time
- `prevent_destroy = true` on critical resources (databases, buckets, KMS keys)
- `plan` before every `apply`. Review the diff. Never auto-apply to production without human approval
- Pin provider versions with pessimistic constraints: `~> 5.0` locks to 5.x not 6.x. Full pins for production stability
- `required_version` in every root module. Prevents silent version drift across team members

## Workflow
- CI pattern: `plan` on PR (post as comment), `apply` on merge to main. Never apply from developer laptops in production
- GitOps orchestration: Atlantis (self-hosted, PR-driven), Spacelift or env0 for team workflows, audit trails, and drift detection
- `terraform fmt -recursive` and `terraform validate` in CI. Fail on violations
- `tflint` for provider-specific lint. `checkov` or `tfsec` for security misconfigurations. Both in CI pre-apply
- Infracost in CI to surface cost delta per PR before apply
- Drift detection: scheduled `plan` runs that alert on non-empty diffs
- `terraform-docs` to auto-generate module README from variables and outputs. Enforce via CI check
- `tfenv` for CLI version management. Commit `.terraform-version` to repo

## Module design
- Modules for reusable patterns. Flat root module for env-specific wiring
- Required variables explicit. Optional variables with sane defaults
- Expose only necessary outputs. `sensitive = true` on any output with secret values
- Version-pin module sources (registry or git tag). Never `?ref=main` — breaks reproducibility
- Keep modules small and focused. One domain per module
- `for_each` over `count` for resources with identity (databases, buckets, queues). `count` only for truly homogeneous replicas
- `moved` blocks when renaming or refactoring resources. `removed` blocks when deleting managed resources
- Variable validation with custom error messages: `validation { condition = ... error_message = "..." }`

## Code quality
- Consistent naming: `<env>-<service>-<resource>`. Pick one convention, enforce via `tflint`
- `locals` for repeated expressions. No duplicated logic across resources
- `terraform_data` (1.4+) over deprecated `null_resource` for triggers and lifecycle hooks
- Avoid `local-exec` provisioners — side effects that survive plan/apply cycles. Use provider resources
- `lifecycle` blocks only when needed. Document `ignore_changes` with a comment explaining why
- Separate `data` source lookups from resource definitions. No inline data lookups mixed into resource arguments
- Terragrunt for DRY multi-env root module wiring when directory-per-environment leads to excessive duplication

## Testing
- `terraform test` (native, 1.6+) for unit and integration testing of modules
- `check` blocks for post-apply assertions: validate actual resource state beyond what Terraform tracks
- Terratest (Go) for complex integration tests requiring real infra provisioning and teardown
- Test variable edge cases: empty strings, null optionals, boundary values in validation blocks

## Tooling reference
| Tool                         | Purpose                             |
|------------------------------|-------------------------------------|
| `tfenv`                      | CLI version management              |
| `terraform fmt`              | Formatting                          |
| `tflint`                     | Provider-aware linting              |
| `checkov` / `tfsec`          | Security misconfiguration scanning  |
| Infracost                    | Cost delta per PR                   |
| Atlantis                     | Self-hosted GitOps PR automation    |
| `terraform-docs`             | Auto-generated module documentation |
| Terragrunt                   | DRY multi-env root module wiring    |
| `terraform test` / Terratest | Module testing                      |