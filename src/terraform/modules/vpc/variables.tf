variable "cluster_name" {
  type        = string
  description = "Cluster name — used as resource name prefix and EKS subnet tags"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block"
  default     = "10.28.0.0/22"
}

variable "availability_zones" {
  type        = list(string)
  description = "Exactly 3 AZs"
}

variable "region" {
  type        = string
  description = "AWS region"
}
