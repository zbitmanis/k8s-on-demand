variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "region" {
  type        = string
  description = "AWS region"
}

variable "metrics_bucket_name" {
  type        = string
  description = "S3 bucket for Thanos metrics (workflow-runner needs read access for artifact uploads)"
}

variable "artifacts_bucket_name" {
  type        = string
  description = "S3 bucket for Argo Workflow artifacts"
}

variable "google_saml_metadata_xml" {
  type        = string
  sensitive   = true
  default     = null
  description = "Google Workspace SAML IdP metadata XML. When null the SAML provider and ops-cluster-access role are not created. Stored as GitHub Actions secret GOOGLE_SAML_METADATA_XML."
}

variable "google_workspace_domain" {
  type        = string
  default     = ""
  description = "Google Workspace hosted domain (e.g. company.com). Used as SAML:hd condition to restrict cluster access to company employees."
}
