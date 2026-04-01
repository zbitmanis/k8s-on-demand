output "lambda_function_name" {
  description = "Name of the cluster-suspend Lambda function"
  value       = aws_lambda_function.cluster_suspend.function_name
}

output "lambda_function_arn" {
  description = "ARN of the cluster-suspend Lambda function"
  value       = aws_lambda_function.cluster_suspend.arn
}

output "lambda_role_arn" {
  description = "ARN of the IAM role attached to the Lambda"
  value       = aws_iam_role.suspend_lambda.arn
}

output "ssm_prefix" {
  description = "SSM Parameter Store prefix where node group sizes are stored during suspend"
  value       = local.ssm_prefix
}

output "suspend_eventbridge_rule_arn" {
  description = "ARN of the EventBridge suspend schedule rule (empty string if enable_schedule = false)"
  value       = var.enable_schedule ? aws_cloudwatch_event_rule.suspend_schedule[0].arn : ""
}

output "resume_eventbridge_rule_arn" {
  description = "ARN of the EventBridge resume schedule rule (empty string if enable_schedule = false)"
  value       = var.enable_schedule ? aws_cloudwatch_event_rule.resume_schedule[0].arn : ""
}
