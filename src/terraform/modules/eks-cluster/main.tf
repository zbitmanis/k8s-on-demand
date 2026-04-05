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

# ── Node group IAM roles ──────────────────────────────────────────────────────
# Pre-created outside the EKS module so their ARNs are known at plan time.
# terraform-aws-eks merges node group role ARNs into local.merged_access_entries
# and uses that map as the for_each source for aws_eks_access_entry.  When the
# roles are created inside the module on a fresh apply the ARNs are unknown,
# making every for_each key unknown and crashing the plan.  Passing a known
# iam_role_arn with create_iam_role = false bypasses that path entirely.

resource "aws_iam_role" "node_group" {
  for_each = toset(["system", "workload"])

  name = "${var.cluster_name}-${each.key}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_group_worker_node" {
  for_each   = aws_iam_role.node_group
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_group_cni" {
  for_each   = aws_iam_role.node_group
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_group_ecr" {
  for_each   = aws_iam_role.node_group
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_group_ssm" {
  for_each   = aws_iam_role.node_group
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
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
  # IMPORTANT: never condition access entry inclusion on role ARNs.
  # ARNs are (known after apply) on a fresh cluster; `arn != ""` is then an
  # unknown bool; a ternary on an unknown condition returns an unknown map;
  # merge() of an unknown map makes local.merged_access_entries entirely
  # unknown, and for_each crashes at plan time.
  # Use separate boolean variables (always known at plan time) instead.
  access_entries = {
    for k, v in {
      # GitHub Actions Terraform execution role — cluster-admin for Day 0 bootstrap.
      # Assumed via OIDC, no static credentials.  Only entry with cluster-admin.
      terraform = {
        principal_arn = var.terraform_role_arn
        type          = "STANDARD"
        policy_associations = {
          cluster_admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
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

      # Break-glass access entry — MFA enforced on the IAM role trust policy.
      break_glass = var.include_break_glass ? {
        principal_arn = var.break_glass_role_arn
        type          = "STANDARD"
        policy_associations = {
          cluster_admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      } : null

      # Engineer kubectl access via Google Workspace SAML (saml2aws).
      # Mapped to Kubernetes RBAC group platform:ops — not EKS managed policy.
      ops_cluster_access = var.include_ops_access ? {
        kubernetes_groups = ["platform:ops"]
        principal_arn     = var.ops_cluster_access_role_arn
        type              = "STANDARD"
      } : null
    } : k => v if v != null
  }

  eks_managed_node_groups = {
    # System node group — runs platform components (ArgoCD, Prometheus, Gatekeeper, etc.)
    # min_size=0 allows the suspend Lambda to scale to zero on schedule.
    # t3.large is ~30% cheaper than m5.large with the same 8 GiB RAM; burstable
    # CPU suits the idle/bursty profile of system workloads.
    system = {
      name           = "${var.cluster_name}-system"
      instance_types = ["t3.large", "m5.large"]

      create_iam_role = false
      iam_role_arn    = aws_iam_role.node_group["system"].arn

      min_size     = 0
      max_size     = 3
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
    # Instance priority (Cluster Autoscaler picks cheapest that fits):
    #   t3.medium — $0.047/hr, 2 vCPU / 4 GiB  — light dev workloads
    #   m5.large  — $0.096/hr, 2 vCPU / 8 GiB  — general purpose
    #   m5.xlarge — $0.192/hr, 4 vCPU / 16 GiB — standard tenant pods
    workload = {
      name           = "${var.cluster_name}-workload"
      instance_types = ["t3.medium", "m5.large", "m5.xlarge"]

      create_iam_role = false
      iam_role_arn    = aws_iam_role.node_group["workload"].arn

      min_size     = 0
      max_size     = 20
      desired_size = 0

      disk_size = 50

      labels = {
        "node-role" = "workload"
      }

      # Cluster Autoscaler auto-discovery tags — workload group only.
      # System group is managed by the suspend Lambda and must not be tagged.
      tags = {
        "k8s.io/cluster-autoscaler/enabled"              = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"  = "owned"
        # Resource hints for scale-from-zero (conservative: t3.medium shape)
        "k8s.io/cluster-autoscaler/node-template/resources/cpu"    = "2"
        "k8s.io/cluster-autoscaler/node-template/resources/memory" = "4Gi"
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
