data "aws_caller_identity" "current" {}

# ── GitHub Actions OIDC provider ─────────────────────────────────────────────

data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
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

# ── Google Workspace SAML provider ───────────────────────────────────────────
# Enables engineers to obtain temporary AWS credentials via Google Workspace SSO.
# Metadata XML is downloaded from Google Admin Console when creating the custom
# SAML app (see docs/iam-conventions.md for setup steps).
# ACS URL in Google Admin: https://signin.aws.amazon.com/saml
# Entity ID in Google Admin: urn:amazon:webservices

resource "aws_iam_saml_provider" "google_workspace" {
  count                  = var.google_saml_metadata_xml != null ? 1 : 0
  name                   = "google-workspace-saml"
  saml_metadata_document = var.google_saml_metadata_xml
}

# ── platform-ops-cluster-access ──────────────────────────────────────────────
# Human operator kubectl access for dev/sandbox clusters.
# Assumed via Google Workspace SAML federation using saml2aws CLI tool.
# Session duration: 8 hours (suitable for a full working day on a dev cluster).
# Access scope: SAML:hd restricted to company domain — no per-group enforcement
# needed for dev/sandbox. Kubernetes RBAC (platform:ops ClusterRoleBinding) is
# the effective permissions boundary.
# Only created when google_saml_metadata_xml is provided.

data "aws_iam_policy_document" "ops_cluster_access_trust" {
  count = var.google_saml_metadata_xml != null ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithSAML"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_saml_provider.google_workspace[0].arn]
    }

    # Required by AWS for all direct IAM SAML role assumptions.
    condition {
      test     = "StringEquals"
      variable = "SAML:aud"
      values   = ["https://signin.aws.amazon.com/saml"]
    }

    # Restrict to engineers on the company Google Workspace domain.
    condition {
      test     = "StringEquals"
      variable = "SAML:hd"
      values   = [var.google_workspace_domain]
    }
  }
}

resource "aws_iam_role" "ops_cluster_access" {
  count                = var.google_saml_metadata_xml != null ? 1 : 0
  name                 = "platform-ops-cluster-access"
  assume_role_policy   = data.aws_iam_policy_document.ops_cluster_access_trust[0].json
  max_session_duration = 28800  # 8 hours — covers a full working day on dev/sandbox
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
