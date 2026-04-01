output "tf_state_bucket" {
  description = "S3 bucket name for Terraform state — set as TERRAFORM_STATE_BUCKET secret in GitHub Actions"
  value       = aws_s3_bucket.tf_state.bucket
}

output "tf_lock_table" {
  description = "DynamoDB table name for Terraform state locking — set as TERRAFORM_LOCK_TABLE secret"
  value       = aws_dynamodb_table.tf_locks.name
}

output "ecr_repository_url" {
  description = "ECR repository URL for platform-scripts image"
  value       = aws_ecr_repository.platform_scripts.repository_url
}

output "thanos_metrics_bucket" {
  description = "S3 bucket for Thanos long-term metrics"
  value       = aws_s3_bucket.thanos_metrics.bucket
}

output "argo_artifacts_bucket" {
  description = "S3 bucket for Argo Workflow artifacts"
  value       = aws_s3_bucket.argo_artifacts.bucket
}
