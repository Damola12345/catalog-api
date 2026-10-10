variable "bucket_name" {
  description = "Globally unique name for the state bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name (3-63 chars, lowercase, digits, dots, hyphens)."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN for SSE. Null uses the AWS-managed aws/s3 key."
  type        = string
  default     = null
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep superseded state versions before expiry."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to the bucket."
  type        = map(string)
  default     = {}
}
