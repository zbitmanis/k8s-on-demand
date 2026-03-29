data "aws_caller_identity" "current" {}

# ── Permission boundary applied to all tenant IRSA roles ─────────────────────
# Prevents tenant roles from escalating privileges beyond their intended scope.

data "aws_iam_policy_document" "tenant_boundary" {
  statement {
    sid    = "DenyIAM"
    effect = "Deny"
    actions = [
      "iam:*",
      "organizations:*",
      "account:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "RestrictRegion"
    effect = "Deny"
    not_actions = [
      "iam:*",
      "sts:*",
      "s3:*",
      "secretsmanager:*",
    ]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "AllowScopedActions"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "tenant_boundary" {
  name        = "platform-tenant-irsa-boundary"
  description = "Permission boundary for all tenant IRSA roles"
  policy      = data.aws_iam_policy_document.tenant_boundary.json
}

locals {
  tenant_set = toset(var.tenant_ids)
}

# ── Trust policy factory ──────────────────────────────────────────────────────

data "aws_iam_policy_document" "external_secrets_trust" {
  for_each = local.tenant_set

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${each.key}:external-secrets"]
    }
  }
}

data "aws_iam_policy_document" "thanos_sidecar_trust" {
  for_each = local.tenant_set

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:monitoring:prometheus"]
    }
  }
}

# ── external-secrets IRSA role ────────────────────────────────────────────────

resource "aws_iam_role" "external_secrets" {
  for_each = local.tenant_set

  name                 = "${each.key}-external-secrets"
  assume_role_policy   = data.aws_iam_policy_document.external_secrets_trust[each.key].json
  permissions_boundary = aws_iam_policy.tenant_boundary.arn
}

data "aws_iam_policy_document" "external_secrets_policy" {
  for_each = local.tenant_set

  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:/${each.key}/*"]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  for_each = local.tenant_set

  name   = "external-secrets"
  role   = aws_iam_role.external_secrets[each.key].name
  policy = data.aws_iam_policy_document.external_secrets_policy[each.key].json
}

# ── thanos-sidecar IRSA role ──────────────────────────────────────────────────

resource "aws_iam_role" "thanos_sidecar" {
  for_each = local.tenant_set

  name                 = "${each.key}-thanos-sidecar"
  assume_role_policy   = data.aws_iam_policy_document.thanos_sidecar_trust[each.key].json
  permissions_boundary = aws_iam_policy.tenant_boundary.arn
}

data "aws_iam_policy_document" "thanos_sidecar_policy" {
  for_each = local.tenant_set

  statement {
    actions = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.metrics_bucket_name}",
      "arn:aws:s3:::${var.metrics_bucket_name}/${each.key}/*",
    ]
  }
}

resource "aws_iam_role_policy" "thanos_sidecar" {
  for_each = local.tenant_set

  name   = "thanos-sidecar"
  role   = aws_iam_role.thanos_sidecar[each.key].name
  policy = data.aws_iam_policy_document.thanos_sidecar_policy[each.key].json
}

# ── load-balancer-controller IRSA role ───────────────────────────────────────

resource "aws_iam_role" "load_balancer" {
  for_each = local.tenant_set

  name                 = "${each.key}-load-balancer-controller"
  assume_role_policy   = data.aws_iam_policy_document.external_secrets_trust[each.key].json
  permissions_boundary = aws_iam_policy.tenant_boundary.arn
}

resource "aws_iam_role_policy_attachment" "load_balancer" {
  for_each = local.tenant_set

  role       = aws_iam_role.load_balancer[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
}

# ── ebs-csi-driver IRSA role ──────────────────────────────────────────────────

resource "aws_iam_role" "ebs_csi" {
  for_each = local.tenant_set

  name                 = "${each.key}-ebs-csi-driver"
  assume_role_policy   = data.aws_iam_policy_document.external_secrets_trust[each.key].json
  permissions_boundary = aws_iam_policy.tenant_boundary.arn
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  for_each = local.tenant_set

  role       = aws_iam_role.ebs_csi[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
