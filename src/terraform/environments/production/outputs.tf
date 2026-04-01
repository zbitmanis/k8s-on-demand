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
  description = "IAM role ARN for GitHub Actions Terraform execution"
  value       = module.iam_management.terraform_execution_role_arn
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
