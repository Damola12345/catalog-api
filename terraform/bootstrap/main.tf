# Bootstrap root: creates the remote-state bucket that every other root uses.
#
# Chicken-and-egg: the bucket can't hold its own state before it exists, so
# the first apply uses local state. After that, uncomment the backend block
# below and run `terraform init -migrate-state` to move this root's state into
# the bucket it just created. See README → Terraform → Bootstrap.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.81"
    }
  }

  # backend "s3" {
  #   bucket       = "<state bucket from output>"
  #   key          = "bootstrap/terraform.tfstate"
  #   region       = "eu-central-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Root      = "bootstrap"
  }
  # Account ID suffix keeps the globally-unique name predictable per account.
  bucket_name = coalesce(var.state_bucket_name, "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}")
}

module "state_bucket" {
  source = "../modules/state-bucket"

  bucket_name = local.bucket_name
}
