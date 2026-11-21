data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "preview" {
  name = var.eks_cluster_name
}

# The cluster's OIDC provider is a prerequisite for IRSA on AWS Load Balancer
# Controller and ExternalDNS. Associate it with the cluster before applying.
data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.preview.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.github_oidc_provider_arn == "" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  github_provider_arn = var.github_oidc_provider_arn == "" ? aws_iam_openid_connect_provider.github[0].arn : var.github_oidc_provider_arn
  eks_oidc_host       = replace(data.aws_eks_cluster.preview.identity[0].oidc[0].issuer, "https://", "")
  prefix              = "${var.project_id}-preview"
}

resource "aws_ecr_repository" "web" {
  name                 = "${local.prefix}-web"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "api" {
  name                 = "${local.prefix}-api"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_acm_certificate" "preview" {
  domain_name       = "*.${var.preview_domain}"
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for dvo in aws_acm_certificate.preview.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "preview" {
  certificate_arn         = aws_acm_certificate.preview.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Only the PR build job assumes this role; deploys are pulled by Argo CD.
      values = ["repo:${var.github_owner}/${var.github_repo}:pull_request"]
    }
  }
}

# GitOps: GitHub Actions can only push images. It has no EKS access entry;
# Argo CD inside the cluster deploys from Git.
resource "aws_iam_role" "github_preview" {
  name               = "${local.prefix}-github"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

data "aws_iam_policy_document" "github_preview" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
      "ecr:BatchGetImage", "ecr:DescribeImages"
    ]
    resources = [aws_ecr_repository.web.arn, aws_ecr_repository.api.arn]
  }
}

resource "aws_iam_role_policy" "github_preview" {
  name   = "preview-ecr-push"
  role   = aws_iam_role.github_preview.id
  policy = data.aws_iam_policy_document.github_preview.json
}

data "aws_iam_policy_document" "external_dns_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_host}:sub"
      values   = ["system:serviceaccount:external-dns:external-dns"]
    }
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "${local.prefix}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_trust.json
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]
  }
  statement {
    actions   = ["route53:ListHostedZones", "route53:ListHostedZonesByName", "route53:GetChange"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "preview-zone-only"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}
