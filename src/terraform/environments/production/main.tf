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

  google_saml_metadata_xml = var.google_saml_metadata_xml
  google_workspace_domain  = var.google_workspace_domain
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
  terraform_role_arn          = module.iam_management.terraform_execution_role_arn
  argocd_role_arn             = module.iam_management.argocd_role_arn
  workflow_runner_role_arn    = module.iam_management.workflow_runner_role_arn
  break_glass_role_arn        = module.iam_management.break_glass_role_arn
  ops_cluster_access_role_arn = module.iam_management.ops_cluster_access_role_arn
}

module "eks_addons" {
  source = "../../modules/eks-addons"

  cluster_name       = module.eks_cluster.cluster_name
  cluster_version    = var.kubernetes_version
  oidc_provider_arn  = module.eks_cluster.oidc_provider_arn
  oidc_provider_url  = module.eks_cluster.oidc_provider_url

  depends_on = [module.eks_cluster]
}

data "aws_caller_identity" "current" {}

module "suspend_lambda" {
  source = "../../modules/suspend-lambda"

  cluster_name                = var.cluster_name
  aws_region                  = var.region
  aws_account_id              = data.aws_caller_identity.current.account_id
  argo_workflow_iam_role_name = module.iam_management.workflow_runner_role_name

  enable_schedule       = true
  suspend_schedule_cron = "cron(0 20 ? * MON-FRI *)"
  resume_schedule_cron  = "cron(0 7 ? * MON-FRI *)"

  depends_on = [module.iam_management]
}

module "iam_tenant_roles" {
  source = "../../modules/iam-tenant-roles"

  tenant_ids            = var.tenant_ids
  oidc_provider_arn     = module.eks_cluster.oidc_provider_arn
  oidc_provider_url     = module.eks_cluster.oidc_provider_url
  metrics_bucket_name   = var.metrics_bucket_name
  region                = var.region
}
