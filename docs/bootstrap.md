# Bootstrap — One-Time Platform Setup

This document covers the one-time steps to create the prerequisite infrastructure before the
first cluster provision. Run these steps once per AWS account/region.

---

## Prerequisites

| Tool | Minimum version |
|---|---|
| Terraform | 1.7+ |
| AWS CLI | 2.x |
| Git | any |

You need an AWS IAM user or role with `AdministratorAccess` to run the bootstrap. This is
the only time static credentials are used — all subsequent operations use OIDC.

---

## Step 1 — Create bootstrap infrastructure

```bash
cd src/terraform/bootstrap

# Authenticate to AWS (one-time, with a user that has AdministratorAccess)
export AWS_PROFILE=your-admin-profile
# or: export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...

terraform init
terraform apply
```

Note the outputs — you will need them in Step 3:

```
tf_state_bucket      = "platform-dev-tf-state"
tf_lock_table        = "platform-dev-tf-locks"
ecr_repository_url   = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/platform-scripts"
thanos_metrics_bucket = "platform-dev-thanos-metrics"
argo_artifacts_bucket = "platform-dev-argo-artifacts"
```

The bootstrap state file (`src/terraform/bootstrap/terraform.tfstate`) is stored locally.
Commit it to the repository — it describes only non-sensitive resource IDs.

---

## Step 2 — Create the `platform-terraform-execution` IAM role

The GitHub Actions OIDC provider is created by the main cluster Terraform (`iam-management`
module). But that module needs a role to assume first — a chicken-and-egg problem.

Create the role manually once:

```bash
# Get your GitHub org and repo
GITHUB_ORG=your-org
GITHUB_REPO=k8s-on-demand
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=eu-west-1

# Create the OIDC provider for GitHub Actions
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Create the role trust policy
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${AWS_ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name platform-terraform-execution \
  --assume-role-policy-document file:///tmp/trust-policy.json

aws iam attach-role-policy \
  --role-name platform-terraform-execution \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

echo "Role ARN: arn:aws:iam::${AWS_ACCOUNT}:role/platform-terraform-execution"
```

---

## Step 3 — Configure GitHub Actions secrets

In your GitHub repository: **Settings → Secrets and variables → Actions → New repository secret**

| Secret name | Value |
|---|---|
| `TERRAFORM_ROLE_ARN` | `arn:aws:iam::<account-id>:role/platform-terraform-execution` |
| `TERRAFORM_STATE_BUCKET` | From Step 1: `platform-dev-tf-state` |
| `TERRAFORM_LOCK_TABLE` | From Step 1: `platform-dev-tf-locks` |
| `AWS_REGION` | `eu-west-1` |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL |
| `THANOS_METRICS_BUCKET` | From Step 1: `platform-dev-thanos-metrics` |
| `ARGO_ARTIFACTS_BUCKET` | From Step 1: `platform-dev-argo-artifacts` |

---

## Step 4 — Configure `terraform.tfvars`

Copy the example and fill in your values:

```bash
cp src/terraform/environments/production/terraform.tfvars.example \
   src/terraform/environments/production/terraform.tfvars

# Edit terraform.tfvars — at minimum, set github_org
```

`terraform.tfvars` is gitignored. Never commit it.

---

## Step 5 — Store platform secrets in AWS Secrets Manager

The platform needs two secrets accessible by ESO from the cluster:

```bash
# Slack webhook URL (for Argo Workflow notifications)
aws secretsmanager create-secret \
  --region eu-west-1 \
  --name /platform/slack-webhook \
  --secret-string '{"url":"https://hooks.slack.com/services/YOUR/WEBHOOK/URL"}'

# GitHub token with workflow:write scope (for Argo → GHA dispatch)
aws secretsmanager create-secret \
  --region eu-west-1 \
  --name /platform/github-token \
  --secret-string '{"token":"ghp_yourtoken"}'
```

---

## Step 6 — Build and push the platform-scripts Docker image

The Argo Workflow templates require the `platform-scripts` image in ECR before any workflow
can run. Trigger the build workflow manually after the ECR repository is created:

```
GitHub → Actions → Build and push platform-scripts image → Run workflow
```

Or push a change to `src/scripts/` to trigger it automatically.

---

## Step 7 — Configure GitHub Environments (for production approval gate)

In your GitHub repository: **Settings → Environments**

Create two environments:
- `staging` — no protection rules (auto-approve)
- `production` — add required reviewers (the platform team)

This enables the approval gate in `provision-cluster.yaml` and `destroy-cluster.yaml` before
any `terraform apply` / `terraform destroy` runs against production.

---

## After Bootstrap

Once all steps above are complete, you can provision the cluster:

```
GitHub → Actions → Provision cluster → Run workflow → environment: staging
```

See `docs/getting-started.md` for the full end-to-end walkthrough.
