# IAM Design & Conventions

## Principles

* **Least privilege** — every role has only the permissions it needs, nothing more
* **IRSA everywhere** — workloads authenticate via IAM Roles for Service Accounts; never node instance profiles
* **No static credentials** — no IAM access keys for any automated process; OIDC or instance metadata only
* **One role per service** — every service that needs AWS access gets its own dedicated IRSA role; roles are never shared across services, even when permissions overlap
* **Tenant scoping** — tenant roles bounded to tenant resources via resource-level conditions
* **No cross-tenant access** — IAM policy conditions enforce the tenant boundary at the AWS level

## Role Taxonomy

### Management Plane

Exist once; managed by CloudFormation (`src/terraform/bootstrap/`) or the `iam-management` Terraform module.

| Role | Used By | Purpose |
|---|---|---|
| `platform-terraform-execution` | GitHub Actions (OIDC) | Day 0 cluster setup — Terraform apply only |
| `platform-argocd-cluster-manager` | ArgoCD | Cluster registration, kubeconfig generation |
| `platform-argo-workflow-runner` | Argo Workflow pods | Dispatch GHA, read tenant config from S3 |
| `platform-break-glass` | Human (MFA) | Emergency cluster access |
| `platform-ops-cluster-access` | Human (Google SAML) | Day-to-day kubectl via `saml2aws` |

### Platform System IRSA

Created in `src/terraform/modules/eks-addons/main.tf` — **one role per service**. Each trust policy is scoped to the exact SA and namespace.

| Role | SA | Namespace | Permissions |
|---|---|---|---|
| `<cluster>-cluster-autoscaler` | `cluster-autoscaler-aws-cluster-autoscaler` | `kube-system` | ASG describe/scale, EC2 launch templates |
| `<cluster>-load-balancer-controller` | `aws-load-balancer-controller` | `aws` | `elasticloadbalancing:*`, EC2 SG/describe, ACM, `iam:CreateServiceLinkedRole` |
| `<cluster>-thanos-sidecar` | `thanos-sidecar` | `monitoring` | S3 R/W on the metrics bucket only |

> **Adding a new platform service that needs AWS:** add a new `aws_iam_role` in `eks-addons/main.tf`. Never reuse an existing role (including `platform-argo-workflow-runner`).

### Per-Tenant IRSA

Created in `src/terraform/modules/iam-tenant-roles/main.tf` — one set per tenant via `for_each`.

| Role Pattern | SA | Namespace | Permissions |
|---|---|---|---|
| `<tenant>-external-secrets` | `external-secrets` | `<tenant>` | `secretsmanager:GetSecretValue` on `/<tenant>/*` |
| `<tenant>-thanos-sidecar` | `prometheus` | `monitoring` | S3 on tenant metrics prefix |
| `<tenant>-load-balancer` | `aws-load-balancer-controller` | `kube-system` | ELB management |
| `<tenant>-ebs-csi-driver` | `ebs-csi-controller-sa` | `kube-system` | EC2 volume lifecycle |

All tenant roles carry a **Permission Boundary** that denies `iam:*`, restricts Secrets Manager to `/<tenant>/*`, and locks API calls to the cluster region.

## Naming Convention

```
# Management plane
platform-<component>
  e.g. platform-argo-workflow-runner

# Platform system IRSA
<cluster-name>-<component>
  e.g. platform-dev-cluster-autoscaler
       platform-dev-load-balancer-controller
       platform-dev-thanos-sidecar

# Per-tenant IRSA
<tenant-id>-<component>
  e.g. acme-corp-external-secrets
```

## IRSA Trust Policy Pattern

Trust policy must bind to the **exact** `namespace:serviceaccount`. Condition variable keys must **not** include the `https://` prefix — use `var.oidc_provider_url` which strips it.

```hcl
condition {
  test     = "StringEquals"
  variable = "${var.oidc_provider_url}:sub"
  values   = ["system:serviceaccount:<namespace>:<sa-name>"]
}
condition {
  test     = "StringEquals"
  variable = "${var.oidc_provider_url}:aud"
  values   = ["sts.amazonaws.com"]
}
```

## EKS Cluster Access

`aws-auth` ConfigMap is **not used**. All access via EKS Access Entry API (`authentication_mode = "API"`). Managed in `src/terraform/modules/eks-cluster/`.

| Entry | Role | Access |
|---|---|---|
| `terraform` | `platform-terraform-execution` | `AmazonEKSClusterAdminPolicy` (cluster scope) |
| `break_glass` | `platform-break-glass` | `AmazonEKSClusterAdminPolicy` (cluster scope) |
| `argocd` | `platform-argocd-cluster-manager` | k8s group `platform:argocd` → RBAC |
| `workflow_runner` | `platform-argo-workflow-runner` | k8s group `platform:workflow-runner` → RBAC |

`argocd` and `workflow_runner` use `kubernetes_groups` — IAM establishes identity, Kubernetes RBAC controls authorization.

## Terraform Execution Role

Defined in CloudFormation (`src/terraform/bootstrap/`), **not in Terraform**. Creating it in Terraform would be circular — the role must exist before Terraform can run. Apply the CFN stack manually once before any pipeline run.

## Key Rules for Code Changes

1. **New platform service needs AWS** → `eks-addons/main.tf`: new `aws_iam_role`, trust scoped to exact SA+namespace, separate inline policy
2. **New tenant resource type** → `iam-tenant-roles/main.tf`: new role in the `for_each`, with Permission Boundary attached
3. **Never share roles** — not even when two services need similar permissions
4. **OIDC condition variable** — always use `oidc_provider_url` (no `https://`); the module variable strips the scheme
5. **IRSA annotation injection** — set via App-of-Apps `helm.values`, not on the child ArgoCD Application (selfHeal reverts child-app parameters)

---

*Operator reference — setup guides, policy JSON, SSO walkthrough, PlantUML diagrams: [`docs/iam-conventions.adoc`](iam-conventions.adoc)*
