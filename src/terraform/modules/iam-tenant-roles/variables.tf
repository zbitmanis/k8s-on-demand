variable "tenant_ids" {
  type        = list(string)
  description = "List of tenant IDs for which to create IRSA roles"
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS cluster OIDC provider ARN"
}

variable "oidc_provider_url" {
  type        = string
  description = "EKS cluster OIDC provider URL without https://"
}

variable "metrics_bucket_name" {
  type        = string
  description = "S3 bucket for Thanos metrics (tenant sidecar roles get write access)"
}

variable "region" {
  type        = string
  description = "AWS region (used to restrict permission boundary)"
}
