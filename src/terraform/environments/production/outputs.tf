output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks_cluster.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks_cluster.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks_cluster.cluster_ca_certificate
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider (for IRSA)"
  value       = module.eks_cluster.oidc_provider_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "terraform_execution_role_arn" {
  description = "ARN of the GHA execution role (from CFN bootstrap)"
  value       = var.terraform_execution_role_arn
}

output "tenant_role_arns" {
  description = "Map of tenant ID to their IRSA role ARNs"
  value       = module.iam_tenant_roles.tenant_role_arns
}

output "workflow_runner_role_arn" {
  description = "IRSA role ARN for Argo Workflow runner pods"
  value       = module.iam_management.workflow_runner_role_arn
}

output "suspend_lambda_name" {
  description = "Name of the cluster-suspend Lambda function"
  value       = module.suspend_lambda.lambda_function_name
}

# ── Google Workspace SAML federation ─────────────────────────────────────────

output "google_saml_provider_arn" {
  description = "ARN of the Google Workspace SAML provider — used as the Role ARN prefix in the SAML attribute mapping"
  value       = module.iam_management.google_saml_provider_arn
}

output "ops_cluster_access_role_arn" {
  description = "IAM role ARN engineers assume via saml2aws — used as the Role ARN suffix in the SAML attribute mapping"
  value       = module.iam_management.ops_cluster_access_role_arn
}

output "saml_acs_url" {
  description = "SAML ACS URL to enter in Google Admin Console when creating the custom SAML app"
  value       = "https://signin.aws.amazon.com/saml"
}

output "saml_sp_entity_id" {
  description = "SP Entity ID to enter in Google Admin Console when creating the custom SAML app"
  value       = "urn:amazon:webservices"
}

output "saml_role_attribute_value" {
  description = "Full value for the https://aws.amazon.com/SAML/Attributes/Role attribute mapping in Google Admin Console: <saml_provider_arn>,<role_arn>"
  value       = "${module.iam_management.google_saml_provider_arn},${module.iam_management.ops_cluster_access_role_arn}"
}
