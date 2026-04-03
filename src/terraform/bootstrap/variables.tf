variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "k8s-od"
}

variable "ecr_image_count" {
  description = "Number of platform-scripts images to retain in ECR"
  type        = number
  default     = 10
}
