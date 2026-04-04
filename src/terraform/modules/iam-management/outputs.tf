output "argocd_role_arn" {
  description = "IAM role ARN for ArgoCD cluster manager"
  value       = aws_iam_role.argocd.arn
}

output "workflow_runner_role_arn" {
  description = "IAM role ARN for Argo Workflow pods"
  value       = aws_iam_role.workflow_runner.arn
}

output "workflow_runner_role_name" {
  description = "Name of the Argo Workflow runner IAM role (for policy attachments)"
  value       = aws_iam_role.workflow_runner.name
}

output "break_glass_role_arn" {
  description = "IAM role ARN for emergency break-glass access"
  value       = aws_iam_role.break_glass.arn
}

output "google_saml_provider_arn" {
  description = "ARN of the Google Workspace SAML provider, or empty string if SAML not configured"
  value       = length(aws_iam_saml_provider.google_workspace) > 0 ? aws_iam_saml_provider.google_workspace[0].arn : ""
}

output "ops_cluster_access_role_arn" {
  description = "IAM role ARN for engineer kubectl access via Google Workspace SAML, or empty string if SAML not configured"
  value       = length(aws_iam_role.ops_cluster_access) > 0 ? aws_iam_role.ops_cluster_access[0].arn : ""
}
