module "vpc" {
  source = "../../modules/vpc"

  cluster_name       = var.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  region             = var.region
}

module "iam_management" {
  source = "../../modules/iam-management"

  cluster_name          = var.cluster_name
  region                = var.region
  github_org            = var.github_org
  github_repo           = var.github_repo
  metrics_bucket_name   = var.metrics_bucket_name
  artifacts_bucket_name = var.artifacts_bucket_name
}

module "eks_cluster" {
  source = "../../modules/eks-cluster"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  intra_subnet_ids   = module.vpc.intra_subnet_ids

  cluster_endpoint_public_access = var.cluster_endpoint_public_access
  argocd_role_arn          = module.iam_management.argocd_role_arn
  workflow_runner_role_arn = module.iam_management.workflow_runner_role_arn
  terraform_role_arn       = module.iam_management.terraform_execution_role_arn
}

module "eks_addons" {
  source = "../../modules/eks-addons"

  cluster_name       = module.eks_cluster.cluster_name
  cluster_version    = var.kubernetes_version
  oidc_provider_arn  = module.eks_cluster.oidc_provider_arn
  oidc_provider_url  = module.eks_cluster.oidc_provider_url

  depends_on = [module.eks_cluster]
}

module "iam_tenant_roles" {
  source = "../../modules/iam-tenant-roles"

  tenant_ids            = var.tenant_ids
  oidc_provider_arn     = module.eks_cluster.oidc_provider_arn
  oidc_provider_url     = module.eks_cluster.oidc_provider_url
  metrics_bucket_name   = var.metrics_bucket_name
  region                = var.region
}
