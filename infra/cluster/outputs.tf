output "cluster_name" {
  description = "Use as eks_cluster_name in infra/terraform and CLUSTER_NAME for the install scripts."
  value       = module.eks.cluster_name
}

output "aws_region" {
  value = var.aws_region
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}
