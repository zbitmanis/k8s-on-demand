variable "region" {
  type        = string
  description = "AWS region for the cluster"
  default     = "eu-central-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment label"
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production"
  }
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
  default     = "platform-dev"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the EKS cluster"
  default     = "1.29"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.28.0.0/22"
}

variable "availability_zones" {
  type        = list(string)
  description = "List of AZs to use (must be 3)"
  default     = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Exactly 3 availability zones are required"
  }
}

variable "tenant_ids" {
  type        = list(string)
  description = "List of tenant IDs for which to pre-create IAM roles"
  default     = ["example-tenant"]
}

variable "state_bucket" {
  type        = string
  description = "S3 bucket name for Terraform state (passed via -backend-config in GHA)"
  default     = ""
}

variable "lock_table" {
  type        = string
  description = "DynamoDB table name for state locking (passed via -backend-config in GHA)"
  default     = ""
}

variable "cluster_endpoint_public_access" {
  type        = bool
  description = "Enable public EKS API endpoint (true for dev/staging, false for production)"
  default     = true
}

variable "terraform_execution_role_arn" {
  type        = string
  description = "ARN of the GHA execution role created by the CFN bootstrap (github-oidc-role.cfn.json). Used as cluster-admin EKS access entry."
}

variable "metrics_bucket_name" {
  type        = string
  description = "S3 bucket for Thanos long-term metric storage"
}

variable "artifacts_bucket_name" {
  type        = string
  description = "S3 bucket for Argo Workflow artifacts"
}

variable "google_saml_metadata_xml" {
  type        = string
  sensitive   = true
  default     = null
  description = "Google Workspace SAML IdP metadata XML. When null the SAML provider and ops-cluster-access role are skipped. Set via GitHub Actions secret GOOGLE_SAML_METADATA_XML."
}

variable "google_workspace_domain" {
  type        = string
  description = "Google Workspace hosted domain for SAML hd condition (e.g. company.com)"
  default     = ""
}
