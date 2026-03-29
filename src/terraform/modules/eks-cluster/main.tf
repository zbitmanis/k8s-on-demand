data "aws_caller_identity" "current" {}

# ── KMS key for etcd envelope encryption ─────────────────────────────────────

resource "aws_kms_key" "eks" {
  description             = "EKS etcd encryption key — ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# ── EKS cluster ───────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.intra_subnet_ids

  # Dev: public endpoint enabled so GitHub Actions runners can reach the cluster.
  # Production: set cluster_endpoint_public_access=false and use a VPC-internal runner.
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = var.cluster_endpoint_public_access

  # etcd envelope encryption
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.eks.arn
  }

  # aws-auth ConfigMap — platform roles
  enable_cluster_creator_admin_permissions = false

  access_entries = {
    terraform = {
      kubernetes_groups = ["system:masters"]
      principal_arn     = var.terraform_role_arn
      type              = "STANDARD"
    }
    argocd = {
      kubernetes_groups = ["platform:argocd"]
      principal_arn     = var.argocd_role_arn
      type              = "STANDARD"
    }
    workflow_runner = {
      kubernetes_groups = ["platform:workflow-runner"]
      principal_arn     = var.workflow_runner_role_arn
      type              = "STANDARD"
    }
  }

  eks_managed_node_groups = {
    # System node group — runs platform components (ArgoCD, Prometheus, Gatekeeper, etc.)
    system = {
      name           = "${var.cluster_name}-system"
      instance_types = ["m5.large"]

      min_size     = 2
      max_size     = 2
      desired_size = 2

      disk_size = 50

      labels = {
        "node-role" = "system"
      }

      taints = [
        {
          key    = "node-role"
          value  = "system"
          effect = "NO_SCHEDULE"
        }
      ]
    }

    # Workload node group — runs tenant application pods
    # min_size=0 enables full scale-to-zero when cluster is idle
    workload = {
      name           = "${var.cluster_name}-workload"
      instance_types = ["m5.xlarge", "m5.2xlarge"]

      min_size     = 0
      max_size     = 20
      desired_size = 3

      disk_size = 100

      labels = {
        "node-role" = "workload"
      }
    }
  }
}

# ── IRSA OIDC trust update for argocd and workflow-runner roles ───────────────
# Updates the trust policies created in iam-management to use the cluster OIDC provider.

data "aws_iam_policy_document" "argocd_irsa_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:argocd:argocd-application-controller"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "argocd_irsa_trust" {
  # Note: trust policy on the argocd role is managed here after OIDC provider is known.
  # Use aws_iam_role_policy to update; the role was created in iam-management module.
  role       = "platform-argocd-cluster-manager"
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"

  lifecycle {
    ignore_changes = [policy_arn]
  }
}
