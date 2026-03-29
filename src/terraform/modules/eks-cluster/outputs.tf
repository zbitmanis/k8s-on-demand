output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "ARN of the EKS cluster OIDC provider (for IRSA)"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "URL of the EKS cluster OIDC provider (without https://)"
  value       = module.eks.oidc_provider
}

output "node_security_group_id" {
  description = "Security group ID shared by all node groups"
  value       = module.eks.node_security_group_id
}
