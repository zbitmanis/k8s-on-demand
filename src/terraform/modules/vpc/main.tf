# VPC layout (10.28.0.0/22, 3 AZs):
#   Public  /26 × 3  — NAT gateway (single), internet-facing ALBs (59 usable IPs each)
#   Private /25 × 3  — system and workload node groups + pods (123 usable IPs each)
#   Intra   /28 × 3  — EKS control plane ENIs only, no internet route (11 usable IPs each)
#
# IP budget: ~624 IPs assigned, ~400 unallocated (reserved for future subnet tiers).
# Risk: VPC CNI pre-warms a full ENI per node by default. At max scale (20 nodes)
# this consumes ~750 IPs. Mitigate by setting WARM_IP_TARGET=2 on aws-node DaemonSet.
#
# Single NAT gateway: reduces cost ~$65/month vs one-per-AZ.
# Trade-off: cross-AZ traffic from private subnets in non-gateway AZs incurs
# $0.01/GB inter-AZ charge, and NAT loss takes down outbound for all AZs.
# Acceptable for dev/cost-optimised environments; use one_nat_gateway_per_az=true
# for production HA.

locals {
  public_subnets  = ["10.28.0.0/26",  "10.28.0.64/26",  "10.28.0.128/26"]
  private_subnets = ["10.28.1.0/25",  "10.28.1.128/25", "10.28.2.0/25"]
  intra_subnets   = ["10.28.3.0/28",  "10.28.3.16/28",  "10.28.3.32/28"]
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
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

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
