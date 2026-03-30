# ── Terraform state bucket ────────────────────────────────────────────────────
resource "aws_s3_bucket" "tf_state" {
  bucket        = "${var.prefix}-tf-state"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── DynamoDB lock table ───────────────────────────────────────────────────────
resource "aws_dynamodb_table" "tf_locks" {
  name         = "${var.prefix}-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ── ECR repository: platform-scripts ─────────────────────────────────────────
resource "aws_ecr_repository" "platform_scripts" {
  name                 = "platform-scripts"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "platform_scripts" {
  repository = aws_ecr_repository.platform_scripts.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last ${var.ecr_image_count} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_image_count
      }
      action = { type = "expire" }
    }]
  })
}

# ── S3: Thanos long-term metrics ─────────────────────────────────────────────
resource "aws_s3_bucket" "thanos_metrics" {
  bucket        = "${var.prefix}-thanos-metrics"
  force_destroy = true   # safe to destroy; metrics are observability data, not source of truth
}

resource "aws_s3_bucket_server_side_encryption_configuration" "thanos_metrics" {
  bucket = aws_s3_bucket.thanos_metrics.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "thanos_metrics" {
  bucket                  = aws_s3_bucket.thanos_metrics.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── S3: Argo Workflow artifacts ───────────────────────────────────────────────
resource "aws_s3_bucket" "argo_artifacts" {
  bucket        = "${var.prefix}-argo-artifacts"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "argo_artifacts" {
  bucket = aws_s3_bucket.argo_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "argo_artifacts" {
  bucket = aws_s3_bucket.argo_artifacts.id
  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "argo_artifacts" {
  bucket                  = aws_s3_bucket.argo_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
