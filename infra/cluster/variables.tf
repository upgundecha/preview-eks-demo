variable "aws_region" {
  type        = string
  description = "AWS Region for the VPC and EKS cluster."
}

variable "cluster_name" {
  type        = string
  default     = "branch-preview"
  description = "Name of the dedicated, non-production preview cluster."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,38}$", var.cluster_name))
    error_message = "Use 3-39 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "kubernetes_version" {
  type        = string
  default     = "1.36"
  description = "EKS Kubernetes minor version."
}

variable "cluster_log_types" {
  type        = list(string)
  default     = ["audit", "api", "authenticator"]
  description = "EKS control-plane log types sent to CloudWatch. Set to [] to turn logging off (cheaper for short tests)."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.60.0.0/16"
  description = "CIDR for the new VPC. Pick one that does not overlap networks you peer with."
}

variable "az_count" {
  type        = number
  default     = 2
  description = "Availability zones to use. The ALB needs at least two."
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "Use 2 or 3 availability zones."
  }
}

variable "node_instance_types" {
  type        = list(string)
  default     = ["t3.large"]
  description = "Instance types for the managed node group."
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type        = number
  default     = 2
  description = "Initial node count. Ignored by the node group after creation."
}

variable "endpoint_public_access_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the public EKS API endpoint. Narrow this to your own IP or VPN egress."
}

variable "load_balancer_controller_chart_version" {
  type        = string
  default     = "3.6.2"
  description = "aws-load-balancer-controller Helm chart version from https://aws.github.io/eks-charts."
}
