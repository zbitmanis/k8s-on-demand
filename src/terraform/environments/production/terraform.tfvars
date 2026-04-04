region             = "eu-central-1"
environment        = "staging"
cluster_name       = "platform-dev"
kubernetes_version = "1.29"

vpc_cidr = "10.28.0.0/22"
availability_zones = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

terraform_execution_role_arn = "arn:aws:iam::070525324311:role/k8s-od-platform-gha-execution"

metrics_bucket_name   = "platform-dev-thanos-metrics"
artifacts_bucket_name = "platform-dev-argo-artifacts"

# Tenants for which IAM roles are pre-created at cluster provision time.
# Add new tenant IDs here before running terraform apply for a new tenant.
tenant_ids = [
  "example-tenant",
]
