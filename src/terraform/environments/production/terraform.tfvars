region             = "eu-west-1"
environment        = "staging"
cluster_name       = "platform-dev"
kubernetes_version = "1.29"

vpc_cidr = "10.0.0.0/16"
availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]

github_org  = "<your-github-org>"
github_repo = "k8s-on-demand"

metrics_bucket_name   = "platform-dev-thanos-metrics"
artifacts_bucket_name = "platform-dev-argo-artifacts"

# Tenants for which IAM roles are pre-created at cluster provision time.
# Add new tenant IDs here before running terraform apply for a new tenant.
tenant_ids = [
  "example-tenant",
]
