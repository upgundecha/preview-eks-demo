output "github_role_arn" {
  value = aws_iam_role.github_preview.arn
}
output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}
output "web_ecr_url" {
  value = aws_ecr_repository.web.repository_url
}
output "api_ecr_url" {
  value = aws_ecr_repository.api.repository_url
}
output "preview_certificate_arn" {
  value = aws_acm_certificate_validation.preview.certificate_arn
}
