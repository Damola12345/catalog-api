provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = merge({
    Project     = var.service_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "${var.github_org}/${var.github_repo}"
  }, var.extra_tags)
}

module "ecr" {
  source = "../modules/ecr"

  name                 = var.service_name
  keep_tagged_count    = var.ecr_keep_tagged_count
  untagged_expiry_days = var.ecr_untagged_expiry_days
}

module "ci_role" {
  source = "../modules/github-oidc-ci-role"

  role_name            = "${var.service_name}-ci"
  github_org           = var.github_org
  github_repo          = var.github_repo
  github_owner_id      = var.github_owner_id
  github_repo_id       = var.github_repo_id
  allowed_refs         = var.ci_allowed_refs
  ecr_repository_arns  = [module.ecr.repository_arn]
  create_oidc_provider = var.create_github_oidc_provider
}