terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.81"
    }
  }
}

# The GitHub OIDC provider is account-wide (one per account). Create it here
# only if nothing else in the account owns it; otherwise look it up.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list omitted: AWS validates GitHub's OIDC certificate against
  # its own trusted CA store (provider >= 5.81 makes it optional).
  tags = var.tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  plain_subjects = [for ref in var.allowed_refs : "repo:${var.github_org}/${var.github_repo}:${ref}"]

  id_subjects = (var.github_owner_id != null && var.github_repo_id != null) ? [
    for ref in var.allowed_refs : "repo:${var.github_org}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:${ref}"
  ] : []

  allowed_subjects = concat(local.plain_subjects, local.id_subjects)
}

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.allowed_subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  description          = "GitHub Actions CI for ${var.github_org}/${var.github_repo}: push images to ECR"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  tags                 = var.tags
}


data "aws_iam_policy_document" "ecr_push" {
  # GetAuthorizationToken is account-level and cannot be resource-scoped.
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push (and the reads a push needs) — only to the named repositories.
  # No Delete*, no Set*Policy, no lifecycle changes.
  statement {
    sid    = "ECRPushToServiceRepo"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.ecr_push.json
}