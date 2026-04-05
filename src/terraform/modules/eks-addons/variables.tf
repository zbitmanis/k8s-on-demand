variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version of the EKS cluster"
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS cluster OIDC provider ARN (for EBS CSI IRSA role)"
}

variable "oidc_provider_url" {
  type        = string
  description = "EKS cluster OIDC provider URL without https://"
}

variable "thanos_bucket" {
  type        = string
  description = "S3 bucket name for Thanos long-term metric storage (used to scope Thanos IRSA policy)"
}
