output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

output "terraform_execution_role_arn" {
  description = "IAM role ARN for GitHub Actions Terraform execution"
  value       = aws_iam_role.terraform_execution.arn
}

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
  description = "ARN of the Google Workspace SAML provider"
  value       = aws_iam_saml_provider.google_workspace.arn
}

output "ops_cluster_access_role_arn" {
  description = "IAM role ARN for engineer kubectl access via Google Workspace SAML (saml2aws)"
  value       = aws_iam_role.ops_cluster_access.arn
}
