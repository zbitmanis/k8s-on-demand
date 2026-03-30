variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "platform-dev"
}

variable "ecr_image_count" {
  description = "Number of platform-scripts images to retain in ECR"
  type        = number
  default     = 10
}
