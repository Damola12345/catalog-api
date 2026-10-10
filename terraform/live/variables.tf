variable "aws_region" {
  description = "AWS region for the service's resources."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name, used for tagging."
  type        = string
  default     = "shared"

  validation {
    condition     = contains(["dev", "staging", "prod", "shared"], var.environment)
    error_message = "environment must be one of dev, staging, prod, shared."
  }
}

variable "service_name" {
  description = "Service name; used for the ECR repository and role naming."
  type        = string
  default     = "catalog-api"
}

variable "github_org" {
  description = "GitHub org/user owning the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID, for ID-based OIDC subjects (see module docs). Null to skip."
  type        = number
  default     = null
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID, for ID-based OIDC subjects. Null to skip."
  type        = number
  default     = null
}

variable "ci_allowed_refs" {
  description = "OIDC subject suffixes allowed to assume the CI role."
  type        = list(string)
  default     = ["ref:refs/heads/main"]
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}

variable "ecr_keep_tagged_count" {
  description = "How many sha-* images to keep for rollback."
  type        = number
  default     = 30
}

variable "ecr_untagged_expiry_days" {
  description = "Days before untagged images expire."
  type        = number
  default     = 7
}

variable "extra_tags" {
  description = "Additional tags merged into the defaults."
  type        = map(string)
  default     = {}
}