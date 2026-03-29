data "aws_caller_identity" "current" {}

# ── GitHub Actions OIDC provider ─────────────────────────────────────────────

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

# ── platform-terraform-execution ─────────────────────────────────────────────
# Used by GitHub Actions to run terraform plan/apply/destroy.
# Trusted only for the specific org/repo via OIDC.

data "aws_iam_policy_document" "terraform_execution_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "terraform_execution" {
  name               = "platform-terraform-execution"
  assume_role_policy = data.aws_iam_policy_document.terraform_execution_trust.json

  lifecycle {
    # Prevent the role from modifying its own trust policy
    ignore_changes = [assume_role_policy]
  }
}

resource "aws_iam_role_policy_attachment" "terraform_execution_admin" {
  role       = aws_iam_role.terraform_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ── platform-argocd-cluster-manager ──────────────────────────────────────────
# Assumed by ArgoCD via IRSA to register/describe EKS clusters.
# OIDC trust is configured after EKS cluster creation (in eks-cluster module).
# Placeholder trust policy here; eks-cluster module updates it.

data "aws_iam_policy_document" "argocd_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "argocd" {
  name               = "platform-argocd-cluster-manager"
  assume_role_policy = data.aws_iam_policy_document.argocd_trust.json
}

data "aws_iam_policy_document" "argocd_policy" {
  statement {
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "argocd" {
  name   = "argocd-cluster-manager"
  role   = aws_iam_role.argocd.name
  policy = data.aws_iam_policy_document.argocd_policy.json
}

# ── platform-argo-workflow-runner ─────────────────────────────────────────────
# Assumed by Argo Workflow pods via IRSA.
# Needs: dispatch GitHub Actions, read Secrets Manager (GH token), read/write S3 artifacts.

data "aws_iam_policy_document" "workflow_runner_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workflow_runner" {
  name               = "platform-argo-workflow-runner"
  assume_role_policy = data.aws_iam_policy_document.workflow_runner_trust.json
}

data "aws_iam_policy_document" "workflow_runner_policy" {
  statement {
    sid       = "ReadGitHubToken"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:/platform/github-token*"]
  }

  statement {
    sid = "WorkflowArtifacts"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.artifacts_bucket_name}",
      "arn:aws:s3:::${var.artifacts_bucket_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "workflow_runner" {
  name   = "argo-workflow-runner"
  role   = aws_iam_role.workflow_runner.name
  policy = data.aws_iam_policy_document.workflow_runner_policy.json
}

# ── platform-break-glass ──────────────────────────────────────────────────────
# Emergency access role. Requires MFA. Not used in normal operations.

data "aws_iam_policy_document" "break_glass_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "break_glass" {
  name               = "platform-break-glass"
  assume_role_policy = data.aws_iam_policy_document.break_glass_trust.json

  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "break_glass_admin" {
  role       = aws_iam_role.break_glass.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
