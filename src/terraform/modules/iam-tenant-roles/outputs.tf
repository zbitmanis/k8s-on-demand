output "tenant_role_arns" {
  description = "Map of tenant ID to their IRSA role ARNs (keyed by role type)"
  value = {
    for tenant_id in var.tenant_ids : tenant_id => {
      external_secrets      = aws_iam_role.external_secrets[tenant_id].arn
      thanos_sidecar        = aws_iam_role.thanos_sidecar[tenant_id].arn
      load_balancer         = aws_iam_role.load_balancer[tenant_id].arn
      ebs_csi               = aws_iam_role.ebs_csi[tenant_id].arn
    }
  }
}
