# Secrets Management

## Principles

* **No secrets in Git** — ever. Not encrypted, not base64-encoded, not in comments.
* **Single source of truth** — AWS Secrets Manager is the canonical secrets store.
* **IRSA-scoped access** — each workload can only read secrets in its own tenant prefix.
* **Automatic rotation** — secrets are rotated on a schedule; pods pick up changes without restarts (via ESO sync).
* **Audit trail** — all secret access is logged to CloudWatch via AWS CloudTrail.

## Secret Storage — AWS Secrets Manager

All secrets are stored in AWS Secrets Manager using a path convention:

```
/<tenant-id>/<component>/<secret-name>

Examples:
  /acme-corp/database/postgres-password
  /acme-corp/app/api-key
  /acme-corp/registry/pull-secret
  /platform/github-token
  /platform/argocd-token
  /platform/slack-webhook
```

Platform-level secrets (used by management cluster components) live under `/platform/`.
Tenant secrets live under `/<tenant-id>/`.

IRSA policies enforce that each tenant role can only access its own prefix.
See [iam-conventions.md](iam-conventions.md) for the IAM policy details.

## Delivery to Pods — External Secrets Operator

External Secrets Operator (ESO) runs as a system app in each tenant cluster.
It watches `ExternalSecret` CRDs and syncs secret values from AWS Secrets Manager
into native Kubernetes Secrets.

### ExternalSecret Example

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: database-credentials
  namespace: acme-corp-prod
spec:
  refreshInterval: 1h               # Re-sync every hour
  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore
  target:
    name: database-credentials       # Kubernetes Secret name
    creationPolicy: Owner
  data:
    - secretKey: password            # Key in the K8s Secret
      remoteRef:
        key: /acme-corp/database/postgres-password
        version: AWSCURRENT          # Always pull latest version
```

### ClusterSecretStore

One `ClusterSecretStore` is configured per tenant cluster, using the tenant’s IRSA role:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-west-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

The `external-secrets` service account is annotated with the tenant IRSA role ARN:

```yaml
metadata:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<account>:role/acme-corp-external-secrets
```

## Secret Lifecycle

### Creating a New Secret

1. Store the secret in AWS Secrets Manager via AWS Console, CLI, or Terraform:

   ```bash
   aws secretsmanager create-secret \
     --name /acme-corp/app/api-key \
     --secret-string '{"api_key":"<value>"}' \
     --region eu-west-1
   ```
2. Create an `ExternalSecret` manifest in the tenant’s Kubernetes namespace:

   ```yaml
   # tenants/acme-corp/argocd/secrets.yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   ...
   ```
3. ArgoCD syncs the manifest to the cluster.
4. ESO reads the secret from Secrets Manager and creates the Kubernetes Secret.
5. Pods reference the Kubernetes Secret normally via `env.valueFrom.secretKeyRef`.

### Rotating a Secret

1. Rotate the value in AWS Secrets Manager (manually or via automatic rotation).
2. ESO picks up the new `AWSCURRENT` version on the next refresh cycle (default: 1h).
3. The Kubernetes Secret is updated.
4. If pods need to pick up the new secret without restart, use a secret volume mount (filesystem updates propagate without pod restart). For environment variables, a pod restart is required — use a tool like Reloader or rely on the Argo Workflow `rotate-secrets` pipeline to perform a rolling restart.

### Automatic Rotation

For database passwords and API keys that support rotation:

* AWS Secrets Manager rotation lambda is configured for the secret
* Rotation schedule: every 30 days (configurable per secret)
* The `rotate-secrets` Argo Workflow runs monthly to verify rotation succeeded and triggers pod rolling restarts where env var injection is used

## Secrets in GitHub Actions

GitHub Actions needs secrets to:

* Assume the Terraform execution role (handled via OIDC — no stored secret)
* Dispatch Argo Workflow `workflow_dispatch` events (requires a GitHub PAT)
* Post Slack notifications

These are stored as GitHub Actions organization-level secrets and injected as environment
variables in workflow steps. They are not stored in AWS Secrets Manager
(GHA cannot reach Secrets Manager before AWS credentials are established).

|     |     |     |
| --- | --- | --- |
| Secret | Storage | Rotation |
| `TERRAFORM_ROLE_ARN` | GHA org secret | On IAM role change |
| `TERRAFORM_STATE_BUCKET` | GHA org secret | Static |
| `GH_TOKEN` (PAT for Argo → GHA) | AWS Secrets Manager `/platform/github-token` | Every 90 days |
| `ARGOCD_TOKEN` | AWS Secrets Manager `/platform/argocd-token` | Every 90 days |
| `SLACK_WEBHOOK_URL` | AWS Secrets Manager `/platform/slack-webhook` | On rotation |

## Platform Internal Secrets

Secrets used by management cluster components (Argo Workflows, Argo Events, scripts):

```
/platform/github-token          → GH PAT for workflow dispatch
/platform/argocd-token          → ArgoCD service account token
/platform/slack-webhook         → Slack incoming webhook URL
/platform/pagerduty-key         → PagerDuty integration key
```

These are injected into management cluster pods via ESO using a dedicated `ClusterSecretStore`
backed by the `platform-argo-workflow-runner` IRSA role (which has `/platform/*` read access).

## Secrets That Must Never Exist in This Repo

* AWS access keys or secret keys
* Kubernetes service account tokens
* TLS private keys
* Database passwords
* API tokens of any kind
* Base64-encoded secrets (these are not encrypted)
* `.env` files with real values

Pre-commit hooks are configured to detect and block common secret patterns using `detect-secrets`.
CI also runs `git-secrets` scan on every PR.

## Emergency Access — Break-glass

If ESO is unavailable or a secret is urgently needed for debugging:

1. Authenticate to AWS Console using the `platform-break-glass` role (requires MFA)
2. Navigate to AWS Secrets Manager → retrieve the secret value
3. Log the access reason in the incident log
4. Do NOT copy secrets to local files — access them only in-memory

Break-glass access is logged to CloudWatch and triggers an alert to `#platform-security`.

## Secret Scanning

* `detect-secrets` pre-commit hook blocks commits containing high-entropy strings or known secret patterns
* GitHub secret scanning is enabled at the organisation level
* A weekly CI job (`secret-scan.yaml`) runs `truffleHop` across the full git history
* Any detection triggers immediate rotation of the potentially exposed secret
