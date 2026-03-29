# ArgoCD Structure

## Role in the Platform

ArgoCD is the GitOps engine for the platform. It owns the desired state of everything
running inside the shared cluster: system components and tenant workloads. No workload is applied via
`kubectl apply` directly — ArgoCD is always the delivery path.

## App-of-Apps Pattern

The platform uses a **Helm-based App-of-Apps** chart. A single parent Helm release generates
individual ArgoCD `Application` manifests for each system component, plus an `ApplicationSet`
for per-tenant workload deployment. This allows:

* Enabling/disabling apps per cluster via `values.yaml` feature flags (`isEnabled`)
* Toggling auto-sync per app (`isEnabledAutoSync`)
* Overriding repo, revision, or project per app while inheriting sane defaults
* Per-tenant value overrides via layered values files
* Dynamic tenant app deployment via ApplicationSet (add tenant config, apps auto-deploy)

## Repository Structure

```
src/
├── app-of-apps/
│   ├── Chart.yaml                                  # Helm chart metadata
│   ├── values.yaml                                 # Default values — source of truth for all apps
│   └── templates/
│       ├── external-secrets-operator.yaml          # System app
│       ├── prometheus.yaml                         # System app
│       ├── ingress-nginx.yaml                      # System app
│       ├── aws-load-balancer-controller.yaml       # System app
│       ├── cert-manager.yaml                       # System app
│       ├── gatekeeper.yaml                         # System app
│       ├── thanos-sidecar.yaml                     # System app
│       └── tenant-applicationset.yaml              # Per-tenant workload ApplicationSet
│
└── applications/                                   # Per-system-app Helm wrapper charts
    ├── external-secrets-operator/
    │   ├── Chart.yaml
    │   └── values.yaml
    ├── prometheus/
    │   ├── Chart.yaml
    │   └── values.yaml
    ├── ingress-nginx/
    │   ├── Chart.yaml
    │   └── values.yaml
    ├── aws-load-balancer-controller/
    │   ├── Chart.yaml
    │   └── values.yaml
    ├── cert-manager/
    │   ├── Chart.yaml
    │   └── values.yaml
    ├── gatekeeper/
    │   ├── Chart.yaml
    │   └── values.yaml
    └── thanos-sidecar/
        ├── Chart.yaml
        └── values.yaml

tenants/                                        # Per-tenant configuration
├── acme-corp/
│   ├── config.yaml                             # Tenant metadata, quotas, tier
│   ├── values/
│   │   └── app-of-apps.yaml                    # App-of-Apps value overrides for this tenant
│   └── argocd/
│       └── apps.yaml                           # Tenant workload Applications (auto-generated or hand-written)
├── globex/
│   └── ...
└── _archived/                                  # Offboarded tenants
    └── old-tenant/
        └── ...
```

## System App Template Pattern

Each system app in `src/app-of-apps/templates/` follows the same structure:

```yaml
{{- if .Values.spec.gitops.applications.<appKey>.isEnabled | default false }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    server: {{ .Values.spec.destination.server }}
    namespace: <target-namespace>
  project: {{ .Values.spec.gitops.applications.<appKey>.project | default "platform-system" }}
  source:
    path: {{ .Values.spec.gitops.applications.<appKey>.appPath }}
    repoURL: {{ .Values.spec.gitops.applications.<appKey>.repoURL | default .Values.spec.default.repoURL }}
    targetRevision: {{ .Values.spec.gitops.applications.<appKey>.targetRevision | default .Values.spec.source.targetRevision }}
    helm:
      valueFiles:
        {{- range $val := .Values.spec.default.helm.valueFiles }}
          - {{ $val }}
        {{- end }}
{{- if .Values.spec.gitops.applications.<appKey>.isEnabledAutoSync | default false }}
  syncPolicy:
    automated: {}
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
{{- end }}
{{- end }}
```

Key behaviours:

* `isEnabled: false` → template renders nothing, app is not created in ArgoCD
* `isEnabledAutoSync: false` → app is created but requires manual sync
* All fields fall back to `spec.default.*` via `| default` — only overrides need to be specified per app
* `resources-finalizer.argocd.argoproj.io` ensures child resources are deleted when the Application is removed

## App-of-Apps values.yaml Structure

All defaults live in `src/app-of-apps/values.yaml`:

```yaml
spec:
  destination:
    server: https://kubernetes.default.svc     # In-cluster (shared cluster)

  default:
    repoURL: https://github.com/<org>/<repo>.git
    helm:
      valueFiles:
        - values.yaml

  source:
    targetRevision: HEAD

  gitops:
    applications:

      externalSecretsOperator:
        appPath: src/applications/external-secrets-operator
        namespace: external-secrets
        isEnabled: true
        isEnabledAutoSync: true

      prometheus:
        appPath: src/applications/prometheus
        namespace: monitoring
        isEnabled: true
        isEnabledAutoSync: true

      ingressNginx:
        appPath: src/applications/ingress-nginx
        namespace: ingress-nginx
        isEnabled: true
        isEnabledAutoSync: true

      awsLoadBalancerController:
        appPath: src/applications/aws-load-balancer-controller
        namespace: kube-system
        isEnabled: true
        isEnabledAutoSync: true

      certManager:
        appPath: src/applications/cert-manager
        namespace: cert-manager
        isEnabled: true
        isEnabledAutoSync: true

      gatekeeper:
        appPath: src/applications/gatekeeper
        namespace: gatekeeper-system
        isEnabled: true
        isEnabledAutoSync: true

      thanosSidecar:
        appPath: src/applications/thanos-sidecar
        namespace: monitoring
        isEnabled: true
        isEnabledAutoSync: true
```

## Per-Tenant Value Overrides

When deploying the AoA to a tenant cluster (the in-cluster case), a per-tenant values file
is layered on top of defaults. This lives at `tenants/<tenant-id>/values/app-of-apps.yaml`:

```yaml
# tenants/acme-corp/values/app-of-apps.yaml
spec:
  gitops:
    applications:
      # Optional: override any system app per tenant
      thanosSidecar:
        isEnabled: true       # Enabled for standard tenants and above
```

The root system AoA Application deploys with both value files:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: system-app-of-apps
  namespace: argocd
spec:
  project: platform-system
  source:
    repoURL: https://github.com/<org>/<repo>.git
    targetRevision: HEAD
    path: src/app-of-apps
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {}
    syncOptions:
      - CreateNamespace=true
```

## Per-Tenant Workload Deployment — ApplicationSet

A single ApplicationSet template generates per-tenant Applications dynamically:

```yaml
# src/app-of-apps/templates/tenant-applicationset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-workloads
  namespace: argocd
spec:
  generators:
  - git:
      repoURL: https://github.com/<org>/<repo>.git
      revision: HEAD
      directories:
      - path: "tenants/*"
        exclude: "_archived"
  template:
    metadata:
      name: "{{path.basenameNormalized}}-workloads"
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: "{{path.basenameNormalized}}-project"
      source:
        repoURL: https://github.com/<org>/<repo>.git
        targetRevision: HEAD
        path: "{{path}}/argocd"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{path.basenameNormalized}}"
      syncPolicy:
        automated: {}
        syncOptions:
          - CreateNamespace=false  # Namespace already created by onboarding workflow
        retry:
          limit: 5
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
```

When a new tenant config is added to `tenants/<tenant-id>/`, the ApplicationSet
automatically discovers it and creates an Application that deploys apps from `tenants/<tenant-id>/argocd/`.

## Adding a New System Application

1. Create `src/applications/<new-app>/Chart.yaml` and `src/applications/<new-app>/values.yaml`
2. Add `src/app-of-apps/templates/<new-app>.yaml` following the template pattern above
3. Add the app entry in `src/app-of-apps/values.yaml` with `isEnabled: false` initially
4. Enable in staging and validate
5. Set `isEnabled: true` in `src/app-of-apps/values.yaml` to roll out to production

## Disabling an App for Specific Tenants

Override in the tenant's values file if needed (though system apps are always deployed):

```yaml
# tenants/budget-tenant/values/app-of-apps.yaml
spec:
  gitops:
    applications:
      thanosSidecar:
        isEnabled: false    # Disabled for free-tier tenants (if desired)
```

## ArgoCD Projects

### `platform-system` Project

Used for system apps (App-of-Apps and all infrastructure components):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform-system
  namespace: argocd
spec:
  sourceRepos:
    - https://github.com/<org>/<repo>.git
  destinations:
    - server: "*"
      namespace: "*"
  clusterResourceWhitelist:
    - group: "*"
      kind: ClusterRole
    - group: "*"
      kind: ClusterRoleBinding
    - group: "*"
      kind: CustomResourceDefinition
    - group: "*"
      kind: Namespace
    - group: "*"
      kind: NetworkPolicy
    - group: "*"
      kind: ResourceQuota
```

### Per-Tenant Projects

One project per tenant, created during onboarding. Tenants deploy only to their own
namespace. Cluster-scoped resources are blacklisted.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: <tenant-id>-project
  namespace: argocd
spec:
  sourceRepos:
    - https://github.com/<org>/<repo>.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: <tenant-id>
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  clusterResourceBlacklist:
    - group: "*"
      kind: "*"
```

The blacklist on `*/*` prevents tenants from creating cluster-scoped resources.
The whitelist on Namespace allows tenants to create sub-namespaces within their own namespace (optional).

## Cluster Registration

The cluster is registered once during bootstrap:

```bash
# Register the cluster (in-cluster context)
argocd cluster add in-cluster \
  --name platform-prod \
  --label platform/role=management \
  --upsert

# Create the root system AoA Application
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: system-app-of-apps
  namespace: argocd
spec:
  project: platform-system
  source:
    repoURL: https://github.com/<org>/<repo>.git
    targetRevision: HEAD
    path: src/app-of-apps
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {}
    syncOptions:
      - CreateNamespace=true
EOF
```

The ApplicationSet for tenant workloads is also part of the system AoA chart and renders automatically.

## Tenant Workload Example

A tenant creates their own workload Applications under `tenants/<tenant-id>/argocd/`:

```yaml
# tenants/acme-corp/argocd/apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: acme-api
  namespace: argocd
spec:
  project: acme-corp-project
  source:
    repoURL: https://github.com/acme/api.git
    targetRevision: main
    path: deploy/k8s
    helm:
      values: |
        replicas: 3
        image: acme-api:v1.2.3
  destination:
    server: https://kubernetes.default.svc
    namespace: acme-corp
  syncPolicy:
    automated: {}
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 2m
```

The ApplicationSet discovers this file and creates an Application that syncs
the tenant's workloads to their namespace.

## Sync Policy Defaults

All system apps use `automated: {}` with `CreateNamespace=true` and a 5-retry backoff.

|     |     |     |
| --- | --- | --- |
| App | Auto-Sync | Retry |
| All system apps | Yes | 5× with 5s/2× backoff, max 3m |
| Tenant workloads | Yes | 5× with 5s/2× backoff, max 2m |
