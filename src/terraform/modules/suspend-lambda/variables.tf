variable "cluster_name" {
  description = "EKS cluster name — used to scope EKS API calls and SSM paths"
  type        = string
}

variable "aws_region" {
  description = "AWS region where the cluster lives"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID — used to scope IAM resource ARNs"
  type        = string
}

variable "argo_workflow_iam_role_name" {
  description = "Name (not ARN) of the IAM role used by the Argo Workflow runner pod (IRSA). The module attaches an InvokeFunction policy to it."
  type        = string
}

variable "enable_schedule" {
  description = "Whether to create EventBridge rules for automatic suspend/resume. Set false in prod or when you want manual-only control."
  type        = bool
  default     = true
}

variable "suspend_schedule_cron" {
  description = "EventBridge cron expression for the hard-suspend schedule (UTC). Default: weekdays at 20:00 UTC."
  type        = string
  default     = "cron(0 20 ? * MON-FRI *)"
}

variable "resume_schedule_cron" {
  description = "EventBridge cron expression for the resume schedule (UTC). Default: weekdays at 07:00 UTC."
  type        = string
  default     = "cron(0 7 ? * MON-FRI *)"
}

variable "wait_for_nodes_on_resume" {
  description = "If true, the Lambda blocks until at least one node per group reaches Active state after resume."
  type        = bool
  default     = false
}

variable "node_ready_timeout_sec" {
  description = "Seconds the Lambda waits for nodes to become ready when wait_for_nodes_on_resume is true."
  type        = number
  default     = 600
}

variable "tags" {
  description = "Tags applied to all resources created by this module"
  type        = map(string)
  default     = {}
}
