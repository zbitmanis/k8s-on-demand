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

  # ── Authentication mode ──────────────────────────────────────────────────────
  # "API" — EKS Access Entry API only.  No aws-auth ConfigMap is created or
  # consulted.  All cluster access is managed through access_entries here and
  # visible in the AWS Console / CloudTrail.
  # Never set to "CONFIG_MAP" for new clusters — that path is deprecated.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  # ── Access entries ────────────────────────────────────────────────────────────
  # Each entry maps one IAM principal to cluster access.
  #
  # Terraform / GitHub Actions role:
  #   Uses AmazonEKSClusterAdminPolicy (EKS managed, cluster-scoped).
  #   This is the ONLY entry that should have cluster-admin level access.
  #   The role is assumed by GHA via OIDC — no static credentials anywhere.
  #
  # ArgoCD + Argo Workflow runner:
  #   Use kubernetes_groups so downstream Kubernetes RBAC (ClusterRoleBindings
  #   in the platform-rbac app) controls exactly what each component can do.
  #   Prefer fine-grained RBAC over EKS managed policies for in-cluster roles.
  # access_entries is a map(any) — use merge() to conditionally include break-glass
  access_entries = merge(
    {
      # GitHub Actions Terraform execution role — cluster-admin for Day 0 bootstrap.
      # Assumed via OIDC, no static credentials.  Only entry with cluster-admin.
      terraform = {
        principal_arn = var.terraform_role_arn
        type          = "STANDARD"
        policy_associations = {
          cluster_admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"   # cluster-wide, not namespace-scoped
            }
          }
        }
      }

      # ArgoCD application controller — mapped to Kubernetes RBAC group.
      # ClusterRoleBindings in the platform-rbac ArgoCD app control actual permissions.
      argocd = {
        kubernetes_groups = ["platform:argocd"]
        principal_arn     = var.argocd_role_arn
        type              = "STANDARD"
      }

      # Argo Workflow runner — mapped to Kubernetes RBAC group.
      workflow_runner = {
        kubernetes_groups = ["platform:workflow-runner"]
        principal_arn     = var.workflow_runner_role_arn
        type              = "STANDARD"
      }
    },

    # Break-glass access entry — only included when the ARN is provided.
    # MFA requirement is enforced on the IAM role trust policy (iam-management module).
    var.break_glass_role_arn != "" ? {
      break_glass = {
        principal_arn = var.break_glass_role_arn
        type          = "STANDARD"
        policy_associations = {
          cluster_admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    } : {},

    # Engineer kubectl access via Google Workspace SAML (saml2aws).
    # Mapped to Kubernetes RBAC group platform:ops — not EKS managed policy.
    # ClusterRoleBinding in platform-rbac app controls actual permissions.
    var.ops_cluster_access_role_arn != "" ? {
      ops_cluster_access = {
        kubernetes_groups = ["platform:ops"]
        principal_arn     = var.ops_cluster_access_role_arn
        type              = "STANDARD"
      }
    } : {}
  )

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
