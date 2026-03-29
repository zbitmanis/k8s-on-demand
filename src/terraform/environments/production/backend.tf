# Backend configured at init time via -backend-config flags in GitHub Actions:
#   terraform init \
#     -backend-config="bucket=$TERRAFORM_STATE_BUCKET" \
#     -backend-config="key=cluster/terraform.tfstate" \
#     -backend-config="region=$AWS_REGION" \
#     -backend-config="dynamodb_table=$TERRAFORM_LOCK_TABLE" \
#     -backend-config="encrypt=true"
terraform {
  backend "s3" {}
}
