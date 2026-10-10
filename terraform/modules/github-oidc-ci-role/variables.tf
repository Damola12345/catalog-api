variable "role_name" {
  description = "Name of the IAM role CI assumes."
  type        = string
}

variable "github_org" {
  description = "GitHub organisation or user that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "Repository name (without the org)."
  type        = string
}

variable "github_owner_id" {
  description = <<-EOT
    Numeric ID of the GitHub user/org (`gh api users/<owner> --jq .id`).
    Set together with github_repo_id when the account issues ID-based OIDC
    subjects (repo:OWNER@OWNER_ID/REPO@REPO_ID:...). Null = plain form only.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.github_owner_id == null || try(var.github_owner_id > 0, false)
    error_message = "github_owner_id must be a positive GitHub ID (or null)."
  }
}

variable "github_repo_id" {
  description = "Numeric ID of the repository (`gh api repos/<owner>/<repo> --jq .id`). See github_owner_id."
  type        = number
  default     = null

  validation {
    condition     = var.github_repo_id == null || try(var.github_repo_id > 0, false)
    error_message = "github_repo_id must be the real repository ID — `gh api repos/<owner>/<repo> --jq .id` — not 0."
  }
}

variable "allowed_refs" {
  description = <<-EOT
    OIDC subject suffixes allowed to assume the role, e.g.
    "ref:refs/heads/main" or "environment:production".
    Defaults to main only so pull-request runs cannot obtain credentials.
  EOT
  type        = list(string)
  default     = ["ref:refs/heads/main"]

  validation {
    condition     = length(var.allowed_refs) > 0 && alltrue([for r in var.allowed_refs : !strcontains(r, "*")])
    error_message = "allowed_refs must be non-empty and must not contain wildcards."
  }
}

variable "ecr_repository_arns" {
  description = "ECR repository ARNs the role may push to."
  type        = list(string)

  validation {
    condition     = length(var.ecr_repository_arns) > 0 && alltrue([for a in var.ecr_repository_arns : startswith(a, "arn:aws") && !strcontains(a, "*")])
    error_message = "Provide explicit repository ARNs; wildcards are not allowed."
  }
}

variable "create_oidc_provider" {
  description = "Create the account-wide GitHub OIDC provider. Set false if it already exists."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to created resources."
  type        = map(string)
  default     = {}
}