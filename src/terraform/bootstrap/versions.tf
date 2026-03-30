terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Bootstrap state is stored locally and committed.
  # These resources are created once and almost never change.
  # Do NOT add a remote backend here — it would be circular.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "platform"
      ManagedBy   = "terraform-bootstrap"
      Environment = "shared"
    }
  }
}
