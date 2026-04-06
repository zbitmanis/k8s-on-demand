# Architecture — Quick Reference

**Last Updated:** 2026-04-06
**For details:** see [architecture.adoc](architecture.adoc)

## System Overview

Single shared EKS cluster; tenant isolation per namespace via RBAC, NetworkPolicy, ResourceQuota, Gatekeeper, and ESO scoping.
Fully lifecycle-managed: provisioned on demand (~20-30 min cold start), destroyed when idle (zero cost).

## Day 0 vs Day 1

| Phase | Tool | Scope | Frequency |
|-------|------|-------|-----------|
| **Day 0** | Terraform + GitHub Actions | VPC, EKS, IAM, node groups, OIDC, EKS addons | Once per cluster |
| **Day 0** | Ansible | Node bootstrap, OS config, hardening | Once per node group |
| **Day 1** | Crossplane + AWS Provider | Per-tenant S3, IAM roles, RDS, SQS | Per tenant (GitOps) |
| **Day 1** | Argo Workflows | Namespace provisioning, namespace-level resources | Per tenant |
| **Day 1** | ArgoCD | System apps, tenant workloads, Crossplane Compositions | Continuous sync |

## Component Boundaries

| Component | Owns | Runs | IRSA |
|-----------|------|------|------|
| **Terraform** | VPC, subnets, EKS cluster, IAM roles, OIDC | GitHub Actions | Yes (GitHub OIDC) |
| **Ansible** | Node OS, runtime, hardening | Terraform provisioning | No |
| **ArgoCD** | System apps, tenant workload ApplicationSets | Kube-system (system nodes) | Yes (separate role per app) |
| **Crossplane + AWS Provider** | Per-tenant AWS resources via Compositions | Kube-system (system nodes) | Yes (dedicated role) |
| **Argo Workflows** | Namespace provisioning, quota, RBAC, secrets setup | Namespace: argo-workflows (system nodes) | Yes (dedicated role) |
| **Argo Events** | Webhook ingestion, trigger routing | Namespace: argo-events (system nodes) | No (local event sourcing) |
| **Cluster Autoscaler** | Workload node group scaling | Kube-system (system nodes) | Yes (dedicated role) |
| **Lambda + EventBridge** | System node group suspend/resume | EventBridge schedule | Yes (AWS Lambda execution role) |
| **External Secrets Operator (ESO)** | AWS Secrets Manager → Kubernetes Secret | Kube-system (system nodes) | Yes (dedicated role, scoped by tenant) |
| **Prometheus** | Metric scrape from all namespaces | Namespace: prometheus (system nodes) | No (in-cluster scrape) |
| **Thanos** | Long-term metric storage (S3 sidecar) | Namespace: prometheus (system nodes) | Yes (dedicated role, S3 write only) |
| **Gatekeeper** | Pod security, Kubernetes policy enforcement | Kube-system (system nodes) | No (admission webhook) |

## Node Groups

| Group | Purpose | Taint | Scaling | Node Count |
|-------|---------|-------|---------|------------|
| **System** | ArgoCD, Prometheus, Gatekeeper, ESO, Ingress, Crossplane | `node-role=system:NoSchedule` | Lambda/EventBridge (manual suspend/resume) | 0–3 |
| **Workload** | Tenant application pods | None | Cluster Autoscaler (demand-driven) | 0–20 |

**Requirement:** All system components must tolerate `node-role=system:NoSchedule` and use `nodeSelector: node-role: system`.

## Tenant Isolation

| Boundary | Mechanism | Enforcer |
|----------|-----------|----------|
| **Network** | Default-deny NetworkPolicy + explicit allow rules | Calico/Cilium CNI |
| **Compute** | ResourceQuota + LimitRange per namespace | Kubernetes API admission |
| **RBAC** | Namespace-scoped service accounts, roles; cluster-role-bindings forbidden | Gatekeeper admission |
| **Secrets** | ExternalSecret per namespace; ClusterSecretStore scoped to `/<tenant-id>/*` prefix | ESO + AWS Secrets Manager path restriction |
| **Pod Security** | Gatekeeper constraints: no privileged pods, no host network, no host mounts, no system taint toleration | Gatekeeper (enforcement: `warn` — audit only) |
| **Storage** | Namespace-scoped PVCs; host mounts forbidden | Gatekeeper + Kubernetes API |

## Key Rules (Do Not Violate)

1. **Never `terraform apply` locally** — all applies via GitHub Actions
2. **Terraform is Day 0 only** — no per-tenant resources in Terraform
3. **Crossplane Compositions are the Day 1 API** — tenants request AWS resources via Claims (XRCs), not Terraform
4. **ArgoCD is the source of truth** — no `kubectl apply` directly; all state in Git
5. **Gatekeeper always on** — never disable admission webhooks without platform lead approval
6. **IRSA only** — no static IAM credentials; every service with AWS access gets its own dedicated role
7. **Tenant isolation is mandatory** — every PR touching tenant config or isolation requires isolation review

## Tenant Onboarding Flow

1. Webhook → Argo Events EventSource (HTTP listener)
2. Argo Events Sensor triggers Argo Workflow
3. Argo Workflow validates config, creates namespace, NetworkPolicy, ResourceQuota, RBAC, ArgoCD Project
4. Argo Workflow creates ClusterSecretStore binding for tenant
5. Argo Workflow creates Crossplane XRC Claims (S3, IAM, RDS, SQS)
6. Crossplane AWS Provider fulfills Claims → AWS resources created
7. ArgoCD ApplicationSet syncs tenant namespace → tenant apps deployed
8. Platform notifies tenant (API response or webhook)

## Key Architectural Facts

- **Single cluster:** all tenant isolation at namespace + admission level
- **GitOps source of truth:** `src/app-of-apps/` (system) + `tenants/` (per-tenant)
- **Metrics:** Prometheus scrapes all namespaces, labels by `namespace`; Thanos long-term in S3 bucket `k8s-od-thanos-metrics`
- **Secrets:** AWS Secrets Manager → ESO ExternalSecret → Kubernetes Secret per namespace (tenant scoped to `/<tenant-id>/*` prefix)
- **Bootstrap buckets survive cluster destroy:** `k8s-od-thanos-metrics` and `k8s-od-argo-artifacts` (provisioned in `src/terraform/bootstrap/`)
- **Cluster suspend:** Lambda (hard, EventBridge schedule) or Argo Workflow (soft, webhook) → scales system node group to 0
- **Cold start:** ~20-30 min from `terraform apply` to cluster ready
- **On-demand:** fully destroyed when idle; all state recoverable from Git + AWS Secrets Manager

See [architecture.adoc](architecture.adoc) for full component diagrams, data flows, and design rationale.
