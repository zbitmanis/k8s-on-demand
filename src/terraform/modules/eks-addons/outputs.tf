output "ebs_csi_role_arn" {
  description = "IAM role ARN for the EBS CSI driver"
  value       = aws_iam_role.ebs_csi.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for Cluster Autoscaler"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "lbc_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller"
  value       = aws_iam_role.lbc.arn
}

output "thanos_role_arn" {
  description = "IAM role ARN for the Thanos sidecar"
  value       = aws_iam_role.thanos.arn
}
