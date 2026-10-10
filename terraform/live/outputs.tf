output "ecr_repository_url" {
  description = "Push images here; also the image name in k8s/base/kustomization.yaml."
  value       = module.ecr.repository_url
}

output "ci_role_arn" {
  description = "Set as the AWS_CI_ROLE_ARN repository variable in GitHub Actions."
  value       = module.ci_role.role_arn
}

output "ci_trusted_subjects" {
  description = "OIDC subjects the CI role trusts — must include the one CI prints in its 'Show OIDC subject' step."
  value       = module.ci_role.allowed_subjects
}

output "github_actions_variables" {
  description = "Copy-paste values for GitHub → Settings → Secrets and variables → Actions → Variables."
  value = {
    AWS_REGION      = var.aws_region
    AWS_ACCOUNT_ID  = split(".", module.ecr.repository_url)[0]
    AWS_CI_ROLE_ARN = module.ci_role.role_arn
  }
}