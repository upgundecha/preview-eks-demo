# Prerequisite stack: VPC, dedicated EKS cluster, EBS CSI driver with a default
# gp3 StorageClass, and the AWS Load Balancer Controller. Apply this first;
# infra/terraform then adds ECR, ACM and IAM on top of the cluster it creates.

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20 private subnets for pods (VPC CNI gives each pod a VPC IP), /24 public
  # subnets for the internet-facing ALB and the NAT gateway.
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 48 + i)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # one NAT keeps a demo cheap; use one per AZ for resilience
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Subnet discovery tags for the AWS Load Balancer Controller.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public endpoint so you can run the bootstrap scripts from a laptop; Argo CD
  # and the controllers use the private endpoint from inside the VPC.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  endpoint_private_access      = true

  # Access entries only (no aws-auth ConfigMap). Whoever runs this apply gets
  # cluster admin so they can run the bootstrap scripts.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # IAM OIDC provider for IRSA (Load Balancer Controller, EBS CSI, ExternalDNS).
  enable_irsa = true

  # Control-plane logs go to CloudWatch (billed per GB ingested). An empty list
  # turns them off and skips creating the log group.
  enabled_log_types           = var.cluster_log_types
  create_cloudwatch_log_group = length(var.cluster_log_types) > 0

  addons = {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.arn
      # The add-on creates a gp3 "ebs-csi-default-sc" StorageClass marked as
      # default, which the preview PostgreSQL PVCs bind to.
      configuration_values = jsonencode({
        defaultStorageClass = { enabled = true }
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name                  = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

module "load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name                                   = "${var.cluster_name}-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.load_balancer_controller_chart_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    clusterName  = module.eks.cluster_name
    region       = var.aws_region
    vpcId        = module.vpc.vpc_id
    replicaCount = 2
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.load_balancer_controller_irsa.arn
      }
    }
  })]

  # The controller's webhook needs running nodes and the CNI before it starts.
  depends_on = [module.eks]
}
