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

output "prometheus_thanos_role_arn" {
  description = "IAM role ARN for the Prometheus Thanos sidecar container"
  value       = aws_iam_role.prometheus_thanos.arn
}

output "eso_platform_role_arn" {
  description = "IAM role ARN for ESO ClusterSecretStore/platform (/platform/* secrets)"
  value       = aws_iam_role.eso_platform.arn
}

output "crossplane_role_arn" {
  description = "IAM role ARN for the Crossplane AWS Provider"
  value       = aws_iam_role.crossplane.arn
}
