variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "region" {
  type        = string
  description = "AWS region"
}

variable "github_org" {
  type        = string
  description = "GitHub organisation name (for OIDC trust policy on terraform-execution role)"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name"
}

variable "metrics_bucket_name" {
  type        = string
  description = "S3 bucket for Thanos metrics (workflow-runner needs read access for artifact uploads)"
}

variable "artifacts_bucket_name" {
  type        = string
  description = "S3 bucket for Argo Workflow artifacts"
}
