# Secrets Management

## Principles

* **No secrets in Git** — ever
* **AWS Secrets Manager** — single source of truth
* **Path-based scoping** — `/<tenant-id>/*` enforced via IRSA policies
* **ESO for delivery** — ExternalSecret → Kubernetes Secret
* **Automatic rotation** — monthly schedule; ESO syncs on refresh (default 1h)

## Secret Paths

| Scope | Path | Role Access |
|---|---|---|
| **Platform** | `/platform/` | `platform-argo-workflow-runner` |
| **Tenant** | `/<tenant-id>/` | `<tenant>-external-secrets` |

### Platform Secrets

```
/platform/webhook-hmac-secret     → HMAC secret for Argo Events webhooks (all 4 endpoints)
/platform/github-token             → GitHub PAT with workflow:write scope
/platform/slack-webhook            → Slack Incoming Webhook URL
```

Format: `/platform/<secret-type>` as JSON with a `"value"` key (or `"token"` for github-token, `"url"` for slack-webhook).

## Delivery — External Secrets Operator

ESO watches `ExternalSecret` CRDs and syncs from AWS Secrets Manager into native Kubernetes Secrets.

**ClusterSecretStore pattern:**
- One per tenant cluster
- Uses tenant IRSA role (`<tenant>-external-secrets`)
- Syncs to tenant namespace Kubernetes Secrets

**Pod injection:**
- `env.valueFrom.secretKeyRef` for environment variables
- `volumeMounts` for file-based access
- Volume mounts update without pod restart; env vars require restart

## Key Rules

1. **Never commit secrets** — `.gitignore` and pre-commit hooks enforce this
2. **One ClusterSecretStore per tenant** — scoped to `/<tenant-id>/*` path
3. **ESO refresh interval** — default 1h; force sync via annotation if needed
4. **Rotation workflow** — `rotate-secrets` Argo Workflow runs monthly; triggers pod rolling restart for env var injection
5. **GitHub Actions secrets** — OIDC for AWS (no static credentials); GitHub PAT stored in AWS Secrets Manager, injected to GHA via organization secrets

## Emergency Access

Break-glass role (`platform-break-glass`) with MFA:
- Read-only access to AWS Secrets Manager
- All access logged to CloudTrail
- Alert fires on every use

*Full operator guide: see [`docs/secrets.adoc`](secrets.adoc)*
