output "role_arn" {
  description = "Role ARN — set as the AWS_CI_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Role name."
  value       = aws_iam_role.this.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider used in the trust policy."
  value       = local.oidc_provider_arn
}

output "allowed_subjects" {
  description = "Exact OIDC `sub` values the trust policy accepts. Compare with the subject CI prints if AssumeRole is denied."
  value       = local.allowed_subjects
}