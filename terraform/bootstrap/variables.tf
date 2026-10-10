variable "aws_region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project prefix used for naming and tagging."
  type        = string
  default     = "catalog-api"
}

variable "state_bucket_name" {
  description = "Override the state bucket name. Null derives <project>-tfstate-<account-id>."
  type        = string
  default     = null
}
