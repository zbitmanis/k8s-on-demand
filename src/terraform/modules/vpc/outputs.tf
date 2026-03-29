output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (NAT gateways, internet-facing ALBs)"
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "Private subnet IDs (node groups)"
  value       = module.vpc.private_subnets
}

output "intra_subnet_ids" {
  description = "Intra subnet IDs (EKS control plane ENIs)"
  value       = module.vpc.intra_subnets
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = module.vpc.vpc_cidr_block
}
