terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.81"
    }
  }

  # Partial backend configuration: bucket/region come from backend.hcl at
  # init time, so no account-specific values are committed.
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "services/catalog-api/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3-native state locking (no DynamoDB table)
  }
}
