# Multi-Tenant EKS On-Demand Deployment Platform

## Purpose
Automated provisioning and full lifecycle management of a multi-tenant EKS cluster on AWS.
Each tenant receives a dedicated namespace with enforced isolation via RBAC, NetworkPolicies,
ResourceQuotas, and Gatekeeper admission policies. The platform manages the full lifecycle:
cluster provisioning, tenant onboarding, workload delivery, monitoring, and offboarding.

## Cluster Purpose — On-Demand Sandbox / Dev

**This is not a production cluster.** The cluster is on-demand and sandbox/dev-grade:

- **Lifecycle:** provisioned when work begins, fully destroyed when idle (`terraform destroy`)
- **Not always-on:** cold start ~20-30 min; no hibernate or scale-to-zero needed
- **Friction level:** pipelines use lean `workflow_dispatch` inputs with no reviewer gates or environment protection rules
- **Recovery:** all tenant config lives in Git (`tenants/`) — fully recoverable on reprovision

## Isolation Model

**Single shared EKS cluster — tenant isolation per namespace.**

| Concern | Mechanism |
|---|---|
| Network | NetworkPolicy default-deny + explicit allow rules per namespace |
| Compute | ResourceQuota + LimitRange per namespace |
| Access | RBAC namespace-scoped; tenants cannot see or affect other namespaces |
| Policy | Gatekeeper admission constraints (no privileged pods, no host network, etc.) |
| Secrets | ESO ClusterSecretStore scoped to `/<tenant-id>/*` prefix in Secrets Manager |

## Day 0 / Day 1 Split

| Phase | Scope | Tool |
|---|---|---|
| **Day 0** | Cluster bootstrap — VPC, IAM, EKS, node groups | Terraform + GitHub Actions |
| **Day 1** | Per-tenant AWS resources — S3, IAM roles, RDS, SQS | Crossplane (GitOps via ArgoCD) |

Day 0 runs once (or rarely). Day 1 is continuous — every tenant onboarding and
offboarding creates and removes AWS resources through Crossplane Compositions
without touching Terraform state.

## Tech Stack

| Layer | Tool | Responsibility |
|---|---|---|
| Day 0 Infrastructure | Terraform + GitHub Actions | VPC, IAM, EKS cluster (one-time provisioning) |
| Day 0 Configuration | Ansible | Node-level OS and runtime config |
| Day 1 AWS Resources | Crossplane + AWS Provider | Per-tenant S3, IAM roles, RDS, SQS via Compositions |
| GitOps | ArgoCD | System apps + tenant namespace workload delivery |
| Orchestration | Argo Workflows | Tenant lifecycle pipeline execution |
| Automation | Argo Events | Event-driven trigger layer |
| Scripting | Python | Automation scripts, CLI tooling, glue logic |
| Monitoring | Prometheus + Thanos | Metrics collection with namespace-label isolation |

## Critical Rules

- ***Never run `terraform apply` locally*** — all applies go through GitHub Actions
- ***Terraform is Day 0 only*** — do not add per-tenant resources to Terraform; use Crossplane Compositions
- ***Never commit secrets*** — all secrets managed via AWS Secrets Manager + External Secrets Operator
- ***Tenant isolation is mandatory*** — every PR touching tenant config requires isolation review
- ***OIDC only for AWS auth in GHA*** — no static IAM credentials anywhere
- ***ArgoCD is the source of truth*** — do not kubectl apply directly in the cluster
- ***Gatekeeper is always on*** — never disable admission webhooks without platform lead approval
- ***Crossplane Compositions are the API*** — tenants request AWS resources via Claims, never directly

## Repository Layout

```
/
├── CLAUDE.md
├── src/                          # All source code — IaC, GitOps, automation
│   ├── terraform/                # One-time cluster infrastructure
│   │   └── modules/
│   │       ├── vpc/
│   │       ├── eks-cluster/
│   │       ├── iam/
│   │       └── eks-addons/
│   ├── ansible/                  # Node bootstrap (runs once per node group)
│   ├── app-of-apps/              # ArgoCD App-of-Apps Helm chart (system apps)
│   ├── applications/             # Per-system-app Helm wrapper charts
│   ├── crossplane/               # Crossplane XRDs, Compositions, ProviderConfig
│   │   ├── providers/            # AWS provider + ProviderConfig (IRSA)
│   │   ├── xrds/                 # CompositeResourceDefinitions (platform API)
│   │   └── compositions/         # Compositions (how claims map to AWS resources)
│   ├── workflows/                # Argo Workflow templates
│   ├── events/                   # Argo Events definitions
│   └── scripts/                  # Python automation scripts
├── tenants/                      # Per-tenant configuration
│   ├── _registry/
│   │   └── tenants.yaml          # Active tenant registry
│   └── <tenant-id>/
│       ├── config.yaml           # Tenant metadata, tier, quotas
│       ├── values/
│       │   └── app-of-apps.yaml  # Per-tenant app overrides (if any)
│       ├── argocd/
│       │   └── apps.yaml         # Tenant application definitions
│       └── crossplane/
│           └── claims.yaml       # Tenant AWS resource claims (XRCs)
└── docs/                         # Working documentation (Markdown)
```

## Developer Environment

- ***Editor***: VS Code (`code .` to open project)
- ***Suggested extensions***: HashiCorp Terraform, YAML, Kubernetes, GitLens, Python, AsciiDoc

## Documentation Format

- `CLAUDE.md` and all internal Claude instruction files → ***Markdown***
- `docs/**.adoc` generated/published documentation → **AsciiDoc with PlantUML diagrams**

## Docs Index

- [Architecture Overview](docs/architecture.md)
- [Tenant Lifecycle](docs/tenant-lifecycle.md)
- [GitHub Actions & Terraform Pipeline](docs/github-actions.md)
- [Terraform Conventions](docs/terraform.md)
- [Network Topology](docs/network.md)
- [IAM Design](docs/iam-conventions.md)
- [ArgoCD Structure](docs/argocd.md)
- [Argo Workflows](docs/argo-workflows.md)
- [Argo Events](docs/argo-events.md)
- [Ansible Playbooks](docs/ansible.md)
- [Monitoring — Prometheus & Thanos](docs/monitoring.md)
- [Crossplane AWS Resources](docs/crossplane.md)
- [Secrets Management](docs/secrets.md)
