variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version"
  default     = "1.29"
}

variable "region" {
  type        = string
  description = "AWS region"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID from vpc module"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for node groups"
}

variable "intra_subnet_ids" {
  type        = list(string)
  description = "Intra subnet IDs for EKS control plane ENIs"
}

variable "terraform_role_arn" {
  type        = string
  description = "IAM role ARN for Terraform execution (added to aws-auth for bootstrap)"
}

variable "argocd_role_arn" {
  type        = string
  description = "IAM role ARN for ArgoCD (added to aws-auth)"
}

variable "workflow_runner_role_arn" {
  type        = string
  description = "IAM role ARN for Argo Workflow runner (added to aws-auth)"
}

variable "cluster_endpoint_public_access" {
  type        = bool
  description = "Enable public EKS API endpoint. Set true for dev/staging so GHA runners can reach the cluster. False in production (private-only)."
  default     = true
}
