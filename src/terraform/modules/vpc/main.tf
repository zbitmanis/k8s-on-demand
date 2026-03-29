# VPC layout (10.0.0.0/16, 3 AZs):
#   Public  /20 × 3  — NAT gateways, internet-facing ALBs
#   Private /19 × 3  — system and workload node groups
#   Intra   /24 × 3  — EKS control plane ENIs (no internet route)

locals {
  # Derive subnet CIDRs from the VPC CIDR base (assumes 10.0.0.0/16)
  public_subnets  = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
  private_subnets = ["10.0.64.0/19", "10.0.96.0/19", "10.0.128.0/19"]
  intra_subnets   = ["10.0.160.0/24", "10.0.161.0/24", "10.0.162.0/24"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
  intra_subnets   = local.intra_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS requires these tags on subnets for ALB/NLB discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  # Intra subnets have no internet route — used for control plane ENIs only
  intra_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
