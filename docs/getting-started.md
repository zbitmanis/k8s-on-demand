# Getting Started

End-to-end guide for provisioning the platform, onboarding a tenant, and destroying the cluster.

---

## Prerequisites

| Tool | Purpose | Install |
|---|---|---|
| AWS CLI v2 | Bootstrap and local debugging | `brew install awscli` |
| Terraform 1.7+ | Bootstrap only (all applies via GHA) | `brew install terraform` |
| kubectl | Cluster inspection | `brew install kubectl` |
| helm | Chart linting | `brew install helm` |
| argocd CLI | App inspection and debugging | `brew install argocd` |
| Python 3.12 | Running scripts locally | `brew install python@3.12` |

---

## First-Time Setup

If you are setting up this platform for the first time, complete `docs/bootstrap.md` before
continuing here. Bootstrap creates the S3 state bucket, DynamoDB lock table, ECR repository,
and platform IAM role.

---

## Provision the Cluster (~25 min)

1. **Dispatch the provision workflow:**

   ```
   GitHub → Actions → Provision cluster → Run workflow
   ```

   Select `staging` for development. Production requires team approval.

2. **Watch the jobs:**
   - `Terraform apply` (~15 min) — creates VPC, EKS cluster, IAM roles
   - `Bootstrap ArgoCD` (~5 min) — installs ArgoCD, applies App-of-Apps
   - `Wait for system apps` (~5 min) — waits for all 11 apps to reach Healthy+Synced
   - `Notify` — posts the cluster endpoint and kubeconfig command to Slack

3. **Connect kubectl:**

   ```bash
   aws eks update-kubeconfig --name platform-dev --region eu-west-1
   kubectl get nodes
   ```

4. **Verify system apps:**

   ```bash
   kubectl get apps -n argocd
   # All 11 apps should show STATUS=Synced HEALTH=Healthy
   ```

---

## Onboard a Tenant (~3 min)

### Option A — via Argo Events webhook (automated)

```bash
ARGO_EVENTS_URL=https://<argo-events-ingress>/onboard-tenant

curl -X POST "$ARGO_EVENTS_URL" \
  -H "Content-Type: application/json" \
  -d '{"tenant_id": "acme-corp"}'
```

Watch the workflow:

```bash
argo watch -n argo $(argo list -n argo --running -o name | head -1)
```

### Option B — manual CLI

```bash
# 1. Validate config
python src/scripts/validate_tenant_config.py --tenant-id acme-corp

# 2. Provision namespace (requires kubeconfig)
python src/scripts/provision_namespace.py --tenant-id acme-corp

# 3. Submit onboard workflow
argo submit --from workflowtemplate/tenant-onboard \
  -p tenant_id=acme-corp \
  -p scripts_image=<ecr-uri>/platform-scripts:latest \
  -n argo
```

### After onboarding

```bash
kubectl get all -n acme-corp
# Expect: namespace, NetworkPolicy, ResourceQuota, LimitRange, ServiceAccount, Role, RoleBinding

kubectl get appproject acme-corp -n argocd
# Expect: AppProject with destination namespace=acme-corp

kubectl get clustersecretstore acme-corp
# Expect: ClusterSecretStore ready
```

The tenant's ArgoCD ApplicationSet (`tenant-workloads`) will detect the `tenants/acme-corp/`
directory in the repo and create an ArgoCD Application once `tenants/acme-corp/argocd/apps.yaml`
is committed with valid Application manifests.

---

## Add a New Tenant to the Registry

1. Copy the example tenant config:

   ```bash
   cp -r tenants/example-tenant tenants/acme-corp
   ```

2. Edit `tenants/acme-corp/config.yaml` — set `tenant.id`, `tenant.owner_email`, `quotas`.

3. Edit `tenants/acme-corp/argocd/apps.yaml` — point `source.repoURL` at the tenant's app repo.

4. Open a PR. The `pr-validate` workflow will validate the config schema.

5. Merge the PR. Trigger onboarding via webhook or manual CLI (see above).

6. Add the new tenant ID to `src/terraform/environments/production/terraform.tfvars`:

   ```hcl
   tenant_ids = ["example-tenant", "acme-corp"]
   ```

   Then trigger `provision-cluster.yaml` again (Terraform is idempotent — it will only add
   the new IAM roles without recreating the cluster).

---

## Offboard a Tenant

```bash
# Trigger the offboard workflow — it will suspend for manual approval
argo submit --from workflowtemplate/tenant-offboard \
  -p tenant_id=acme-corp \
  -n argo

# When you're ready, approve the offboard:
argo resume <workflow-name> -n argo
```

The workflow will delete the ArgoCD Application, AppProject, and Kubernetes namespace.
Archive the tenant config directory from `tenants/acme-corp/` to `tenants/_archived/acme-corp/`
by committing the directory move.

---

## Destroy the Cluster

1. **Dispatch the destroy workflow:**

   ```
   GitHub → Actions → Destroy cluster → Run workflow
   ```

   Type `destroy` in the confirmation field. Select the target environment.
   Production requires team approval.

2. The workflow:
   - Deletes all LoadBalancer Services (releases ALB/NLB ENIs)
   - Waits 120s for ENI detachment
   - Runs `terraform destroy`
   - Posts confirmation to Slack

3. **Verify cleanup:**

   ```bash
   aws eks list-clusters --region eu-west-1
   # Should not list platform-dev
   ```

---

## Daily Operations

### Check cluster health

```bash
# ArgoCD apps
kubectl get apps -n argocd

# System pods
kubectl get pods -A | grep -v Running | grep -v Completed

# Gatekeeper policy violations (warn mode)
kubectl get constraint -A
```

### Inspect a Gatekeeper violation

```bash
kubectl describe k8snoprivilegedpods no-privileged-pods
# Lists recent violations under .status.violations
```

### Rotate platform secrets

Platform secrets (`/platform/slack-webhook`, `/platform/github-token`) are synced via ESO.
To rotate:

1. Update the secret value in AWS Secrets Manager.
2. ESO syncs the new value within the `refreshInterval` (1h).
3. Or force immediate sync: `kubectl annotate externalsecret platform-slack force-sync=$(date +%s) -n argo`

---

## Troubleshooting

### ArgoCD app stuck in `Progressing`

```bash
argocd app get <app-name>
argocd app logs <app-name>
kubectl describe app <app-name> -n argocd
```

### ESO ExternalSecret not syncing

```bash
kubectl describe externalsecret platform-slack -n argo
# Check .status.conditions for the error

# Verify the IAM role has secretsmanager:GetSecretValue on the path
aws secretsmanager get-secret-value --secret-id /platform/slack-webhook
```

### Gatekeeper blocking a pod

```bash
# Check which constraint is blocking
kubectl describe constraint -A | grep -A5 "violations"

# Temporarily set to warn while debugging (do not leave in warn for production)
kubectl patch k8snoprivilegedpods no-privileged-pods \
  --type=merge -p '{"spec":{"enforcementAction":"warn"}}'
```

### Argo Workflow step failing

```bash
argo get <workflow-name> -n argo
argo logs <workflow-name> -n argo --follow
```
