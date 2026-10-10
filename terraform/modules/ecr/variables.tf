variable "name" {
  description = "Repository name."
  type        = string
}

variable "keep_tagged_count" {
  description = "Number of most recent CI-tagged images to retain."
  type        = number
  default     = 30

  validation {
    condition     = var.keep_tagged_count >= 1
    error_message = "keep_tagged_count must be at least 1."
  }
}

variable "tag_prefixes" {
  description = "Tag prefixes the count-based retention rule applies to."
  type        = list(string)
  default     = ["sha-"]
}

variable "untagged_expiry_days" {
  description = "Days before untagged images are expired."
  type        = number
  default     = 7
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for image encryption. Null uses AES256."
  type        = string
  default     = null
}

variable "force_delete" {
  description = "Allow deleting the repository while it still contains images."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the repository."
  type        = map(string)
  default     = {}
}
