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
  description = "IAM role ARN for Terraform/GitHub Actions execution. Granted AmazonEKSClusterAdminPolicy via EKS Access Entry (API mode). This is the GHA OIDC role — no static credentials."
}

variable "argocd_role_arn" {
  type        = string
  description = "IAM role ARN for ArgoCD (IRSA). Mapped to Kubernetes RBAC group platform:argocd — permissions controlled by ClusterRoleBindings in platform-rbac app."
}

variable "workflow_runner_role_arn" {
  type        = string
  description = "IAM role ARN for Argo Workflow runner pods (IRSA). Mapped to Kubernetes RBAC group platform:workflow-runner."
}

variable "break_glass_role_arn" {
  type        = string
  description = "IAM role ARN for emergency break-glass access (MFA required). Granted AmazonEKSClusterAdminPolicy. Should never be used in normal operations."
  default     = ""
}

variable "include_break_glass" {
  type        = bool
  description = "Whether to create an EKS access entry for the break-glass role. Must be a literal bool — never derive from the ARN, as unknown ARNs make for_each keys unknown at plan time."
  default     = true
}

variable "ops_cluster_access_role_arn" {
  type        = string
  description = "IAM role ARN for engineer kubectl access via Google Workspace SAML (saml2aws). Mapped to Kubernetes RBAC group platform:ops — permissions controlled by ClusterRoleBinding in platform-rbac app."
  default     = ""
}

variable "include_ops_access" {
  type        = bool
  description = "Whether to create an EKS access entry for the ops SAML role. Must be a literal bool — never derive from the ARN, as unknown ARNs make for_each keys unknown at plan time."
  default     = true
}

variable "cluster_endpoint_public_access" {
  type        = bool
  description = "Enable public EKS API endpoint. Set true for dev/staging so GHA runners can reach the cluster. False in production (private-only)."
  default     = true
}
