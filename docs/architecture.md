# Architecture Overview

## System Purpose

This platform provisions isolated tenant namespaces within a single, shared EKS cluster.
All tenants run on the same Kubernetes control plane but maintain strong isolation via NetworkPolicy,
ResourceQuota, RBAC, and Gatekeeper admission constraints. Tenants are onboarded in ~2-3 minutes
via Kubernetes-level operations, with no infrastructure provisioning per tenant.

## Day 0 / Day 1 Split

**Day 0** — runs once per cluster. All cluster-level AWS infrastructure.

**Day 1** — runs per tenant. All tenant-scoped AWS resources, managed as Kubernetes
objects via Crossplane Compositions. No Terraform state involved after Day 0.

| Phase | Tooling | Scope |
| --- | --- | --- |
| Day 0 | Terraform + GitHub Actions | VPC, EKS, IAM roles, OIDC provider, node groups |
| Day 0 | Ansible | Node bootstrap, OS hardening, container runtime |
| Day 1 | Crossplane + AWS Provider | Per-tenant S3 buckets, IRSA roles, RDS, SQS |
| Day 1 | ArgoCD + Argo Workflows | Namespace provisioning, GitOps delivery, lifecycle pipelines |

## Component Responsibilities

| Component | Phase | Owns |
| --- | --- | --- |
| Terraform | Day 0 | Single EKS cluster, VPC, subnets, IAM roles, node groups, OIDC provider |
| GitHub Actions | Day 0 | Terraform execution, drift detection, plan/apply pipeline |
| Ansible | Day 0 | Node bootstrap, runtime config, OS hardening (one-time, shared nodes) |
| Crossplane | Day 1 | Per-tenant AWS resources via Compositions (S3, IAM roles, RDS, SQS) |
| Argo Workflows | Day 1 | Namespace provisioning, quota/policy application, Crossplane claim submission |
| Argo Events | Day 1 | Event ingestion, webhook handling, trigger routing for tenant onboarding |
| ArgoCD | Day 1 | System apps + Crossplane; per-tenant ApplicationSet for namespace-scoped apps |
| Cluster Autoscaler | Day 0 | Workload node group scaling based on pending pod demand (scale-from-zero capable) |
| EventBridge + Lambda | Day 0 | System node group scaling for cost saving (suspend at end of day, resume at start) |
| Prometheus | Observability | Single instance scraping all namespaces; tenant isolation via `namespace` label |
| Thanos | Observability | Long-term metric storage with namespace-aware prefix |
| Gatekeeper | Admission | Cluster-wide policy enforcement: no privileged pods, no host access, system taint blocking |
| Python | Scripting | Automation scripts, CLI tooling, API glue |

## High-Level Architecture

![High-Level Architecture](images/architecture-high-level.svg)

<details>
<summary>PlantUML source — edit <code>docs/diagrams/</code>, then run <code>scripts/generate-diagrams.py</code></summary>

```plantuml
@startuml
skinparam backgroundColor #FAFAFA
skinparam defaultFontName Arial
skinparam rectangleBorderColor #666666
skinparam componentBorderColor #666666

rectangle "Management Plane" {
  component "Argo Events\n(triggers)" as events #LightBlue
  component "Argo Workflows\n(orchestration)" as workflows #LightBlue
  component "ArgoCD\n(GitOps)" as argocd #LightGreen
  component "Crossplane\n(Day 1 resources)" as crossplane #LightSalmon
  component "GitHub Actions\n(Terraform - one-time)" as gha #LightYellow
  component "Thanos\n(aggregator)" as thanos #LightCoral
  component "Prometheus\n(single instance)" as prom #LightCoral
}

events --> workflows : trigger
workflows --> gha : cluster setup only
prom --> thanos : remote write / sidecar
argocd --> crossplane : sync Compositions

component "EventBridge + Lambda\n(suspend/resume)" as lambda #LightYellow
lambda --> sys_nodes : scale system ASG\n(business day boundaries)

rectangle "Shared EKS Cluster" as cluster #E8F5E9 {
  rectangle "System Node Group\n(tainted, 0–3 nodes)" as sys_nodes {
    component "ArgoCD agent" as aa
    component "System apps\n(ESO, Prometheus, Nginx, Gatekeeper)" as sys_apps
  }

  rectangle "Workload Node Group\n(0–20 nodes, CA-managed)" as work_nodes {
    component "Tenant A\nNamespace" as ta
    component "Tenant B\nNamespace" as tb
    component "Tenant N\nNamespace" as tn
  }
}

argocd --> sys_apps : deploy once
argocd --> ta : ApplicationSet → apps
argocd --> tb : ApplicationSet → apps
argocd --> tn : ApplicationSet → apps

ta --> prom : metrics
tb --> prom : metrics
tn --> prom : metrics

cluster --> thanos : Thanos sidecar (from Prometheus)

component "AWS API\n(S3, IAM, RDS, SQS)" as aws_api #LightGray
crossplane --> aws_api : manage resources via Provider
@enduml
```

</details>

## Provisioning Pipeline Flow

![Provisioning Pipeline Flow](images/architecture-pipeline.svg)

<details>
<summary>PlantUML source — edit <code>docs/diagrams/</code>, then run <code>scripts/generate-diagrams.py</code></summary>

```plantuml
@startuml
skinparam backgroundColor #FAFAFA
skinparam defaultFontName Arial

|Cluster Setup\n(one-time)|
start
:GitHub PR: add cluster config;
:GitHub Actions\nterraform apply;
note right: VPC + IAM + EKS + node groups
:Ansible: OS hardening, runtime;
:ArgoCD: deploy system apps;
:Deploy Prometheus, Thanos sidecar;
:Deploy Gatekeeper, ESO;
:Deploy Ingress, Cert-manager;
stop

|Tenant Onboarding\n(per tenant)|
start
:Platform team:\nPOST /onboard-tenant;
:Argo Events: trigger workflow;
:Argo Workflows:\nvalidate config;
:Create namespace;
:Apply NetworkPolicy (default-deny);
:Apply ResourceQuota + LimitRange;
:Create RBAC for tenant;
:Create ArgoCD Project;
:Create ClusterSecretStore binding;
:Crossplane fulfils tenant Claims\n(S3, IAM, RDS via Composition);
:ArgoCD: ApplicationSet sync\n(tenant apps);
:Notify tenant;
stop
@enduml
```

</details>

## Cluster Architecture (Shared)

A single EKS cluster hosts all tenants, structured as:

* **System node group** (tainted `node-role=system:NoSchedule`) — runs platform components (ArgoCD, Prometheus, Gatekeeper, Ingress, ESO). Scales between 0 and 3 nodes; managed by a Lambda/EventBridge schedule for cost saving (`min_size=0` allows full drain on suspend).
* **Workload node group** (no taint) — runs all tenant application pods, isolated per namespace. Starts at `desired_size=0` on provision; Cluster Autoscaler brings nodes up as pods are scheduled and drains them when idle.
* Node groups are shared; tenants are isolated at the namespace + NetworkPolicy + RBAC layer.

### System Node Taint Requirement

Because the workload node group starts at `desired_size=0`, every system component must be schedulable on system nodes from day one. All system workloads — ArgoCD, CoreDNS, EBS CSI controller, metrics-server, Crossplane, Gatekeeper, ESO, and any future system apps — **must** carry both:

```yaml
tolerations:
  - key: node-role
    value: system
    effect: NoSchedule
nodeSelector:
  node-role: system
```

Without these, pods remain `Pending` until a workload node happens to exist, which defeats the separation between the two node groups.

## Tenant Isolation Model

Each tenant is isolated through multiple layers:

| Boundary | Mechanism | Enforcement |
| --- | --- | --- |
| **Network** | Default-deny NetworkPolicy | Kubernetes (Calico/Cilium CNI) |
| **Storage** | Namespace-scoped PVCs | Kubernetes; Gatekeeper blocks host mounts |
| **Compute** | ResourceQuota + LimitRange per namespace | Kubernetes API admission |
| **IAM/Secrets** | Per-tenant ClusterSecretStore scoped to `/<tenant-id>/*` | AWS Secrets Manager path restriction + ESO RBAC |
| **RBAC** | Namespace-scoped service accounts and roles | Kubernetes RBAC, Gatekeeper blocks cluster-scoped creations |
| **Pod Security** | Gatekeeper constraints | Admission controller: prevents privileged pods, hostNetwork, host mounts, system taint toleration |

> **Gatekeeper enforcement mode:** currently set to `warn`. All constraints are active and violations are logged, but pods are not yet blocked. Switching to `deny` requires a full compliance audit of all system and tenant workloads first — do not change enforcement mode without that audit.

## GitOps Source of Truth

The `src/app-of-apps/` directory and `tenants/<tenant-id>/config.yaml` in this repository are the
source of truth for all deployed state. No resource should exist in the cluster that is not
tracked by ArgoCD or Kubernetes ConfigMaps.

See [argocd.md](argocd.md) for structure.

## Key Design Decisions

### Single shared cluster with namespace isolation (vs dedicated clusters)

**Rationale:**
- Dramatically reduced infrastructure cost and operational overhead
- Tenant onboarding in ~2-3 minutes (Kubernetes-level, no IaC)
- Simpler platform maintenance (one control plane, one monitoring stack)
- Shared node resources with strong isolation (NetworkPolicy, RBAC, quotas, admission)

**Trade-offs:**
- Smaller blast radius per tenant (namespace-scoped, not cluster-scoped)
- Cluster upgrades affect all tenants simultaneously (mitigated by maintenance windows and blue-green cluster strategy)
- Resource contention requires careful quota tuning (per-tier quotas defined in config.yaml)

### Argo Workflows for namespace provisioning (vs static manifests)

Argo Workflows provides:
- Stateful orchestration of multi-step onboarding (namespace → quota → RBAC → ESO → ArgoCD project)
- Validation and error handling before resource creation
- Clean audit trail and retry logic
- Integration with Argo Events for webhook-driven triggers

### Per-namespace Prometheus labels (vs separate Prometheus per tenant)

A single Prometheus instance scrapes all namespaces and applies `namespace` label to metrics.
Thanos and Grafana filter by namespace, avoiding duplication and cost.

### ApplicationSet pattern for tenant workloads (vs per-tenant Applications)

ApplicationSet generates Applications dynamically per tenant directory, providing:
- DRY configuration (one template, multiple instances)
- Automatic discovery (add tenant config, ApplicationSet creates Application)
- Namespace-scoped project isolation

### Node group scaling split: Lambda/EventBridge for system nodes, Cluster Autoscaler for workload nodes

Two independent scaling mechanisms operate on two separate node groups:

| Node Group | Mechanism | Trigger | Purpose |
| --- | --- | --- | --- |
| System (0–3 nodes) | Lambda + EventBridge cron | Business day start/end | Cost saving — drain overnight when no tenants are active |
| Workload (0–20 nodes) | Cluster Autoscaler | Pending pod demand | Elastic scaling — scale up when tenants schedule pods, down when idle |

**Why not CA for system nodes?**
System components (ArgoCD, Prometheus, Gatekeeper) run 24/7 during active sessions. CA is reactive to pod
demand; it would never scale system nodes down because pods are always running. Lambda/EventBridge gives
explicit control over when the system group runs, achieving true zero cost outside working hours.

**Why not Lambda for workload nodes?**
Tenant workloads arrive unpredictably and have variable shape. CA matches node provisioning to actual pod
requests using the least-waste expander and scale-from-zero resource hints on the ASG. Lambda-based
schedules would require knowing demand in advance.

The system node group ASG is **not tagged** for CA auto-discovery, preventing CA from interfering with
it. Only the workload group carries `k8s.io/cluster-autoscaler/enabled=true` and the cluster ownership tag.

### Cluster Autoscaler deployment (vs self-managed autoscaling or KEDA)

Cluster Autoscaler is deployed as an ArgoCD-managed Helm chart in `kube-system`, running on system nodes.

**Key configuration choices:**
- `expander: least-waste` — picks the instance type that leaves the smallest unused CPU/memory after
  scheduling pending pods, minimising wasted capacity across the mixed instance type group.
- `balance-similar-node-groups: false` — workload group has one ASG; balancing is not applicable.
- `skip-nodes-with-system-pods: false` — system pods run on system nodes (separate group, not touched
  by CA); setting this to `true` would block scale-down of workload nodes that happen to have
  DaemonSet pods.
- Scale-down delay: 5 minutes. Aggressive to minimise cost; workloads tolerate brief disruption in
  the sandbox/dev context.
- Scale-from-zero: enabled via ASG resource hint tags (`cpu=2`, `memory=4Gi` matching t3.medium shape).
  Without these, CA cannot estimate node capacity before a node exists and will not scale up from 0.

IRSA role (`<cluster-name>-cluster-autoscaler`) is created in `eks-addons` module with write actions
(`SetDesiredCapacity`, `TerminateInstanceInAutoScalingGroup`) conditioned on the CA discovery ASG tags,
preventing the role from touching any other ASG in the account.

### Cluster-wide resources via singleton Kustomize Application

`src/applications/cluster-resources/` is a Kustomize app that owns all cluster-scoped Kubernetes
resources (StorageClasses, PriorityClasses, etc.). ArgoCD Application: `cluster-resources`.

**Rules:**
- Do NOT add StorageClasses or other cluster-scoped resources to Terraform — Terraform owns AWS infrastructure, not Kubernetes objects.
- Do NOT create cluster-scoped resources inside individual app Helm charts — ownership ambiguity and duplication.
- All cluster-scoped Kubernetes resources go in `src/applications/cluster-resources/`. Add a manifest, reference it in `kustomization.yaml`. No other files change.

**Sync wave `-1`:** `cluster-resources` syncs before all other apps (wave 0). Required because thanos-sidecar and prometheus create PVCs on first sync — StorageClass must exist first.

**`Replace=true`:** StorageClass fields are immutable. ArgoCD uses delete-then-create instead of patch. Safe — existing PVCs keep their binding.

**Current contents:** `gp3` StorageClass (EBS CSI, `WaitForFirstConsumer`, encrypted, default class).

### On-demand cost saving via full cluster lifecycle (development use)

The cluster is provisioned at the start of a work session and destroyed when done. This achieves
true zero idle cost — no control plane, no nodes, no NAT gateways running overnight.

**Provision flow** (`provision-cluster` GitHub Actions workflow):
1. `terraform apply` — VPC, IAM, EKS cluster, node groups, addons (~15-18 min)
2. Bootstrap ArgoCD into the fresh cluster (kubectl apply, chicken-and-egg solved in GHA)
3. Apply the App-of-Apps Application → ArgoCD syncs all system apps (~3-5 min)
4. Cluster ready for tenant onboarding

**Destroy flow** (`destroy-cluster` GitHub Actions workflow):
1. Pre-destroy drain: delete all `Service` objects of type `LoadBalancer` across namespaces
   (required — orphaned ALB/NLB ENIs will block VPC deletion)
2. `terraform destroy` — removes all resources cleanly

**State recovery after reprovision:**
- Tenant configs: Git (`tenants/` directory) — fully durable, no data loss
- Secrets: AWS Secrets Manager — survive cluster destroy, re-synced by ESO on next provision
- Metrics: Thanos S3 bucket — survives cluster destroy (Thanos upload interval set to 5 min,
  not 2 h, to minimize in-flight data loss at destroy time)
- ArgoCD state: re-bootstrapped from Git on each provision (stateless by design)

**Cold start time:** ~20-25 min total. Acceptable for development sessions.
