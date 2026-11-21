variable "aws_region" {
  type        = string
  description = "AWS Region containing the existing demo EKS cluster."
}

variable "eks_cluster_name" {
  type        = string
  description = "An existing, dedicated non-production EKS cluster with API access entries enabled."
}

variable "project_id" {
  type        = string
  default     = "branch-demo"
  description = "Short identifier used in AWS names."
  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project_id))
    error_message = "Use 3-24 lowercase letters, digits or hyphens."
  }
}

variable "github_owner" {
  type        = string
  description = "GitHub organization or account owning the demo repository."
}

variable "github_repo" {
  type        = string
  description = "Exact GitHub repository name."
}

variable "preview_domain" {
  type        = string
  description = "Subdomain for previews, e.g. preview.example.com."
}

variable "route53_zone_id" {
  type        = string
  description = "ID of an existing PUBLIC Route 53 hosted zone containing preview_domain."
}

variable "github_oidc_provider_arn" {
  type        = string
  default     = ""
  description = "Existing GitHub OIDC provider ARN; leave empty to create it."
}
