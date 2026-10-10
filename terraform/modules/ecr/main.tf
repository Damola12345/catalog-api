terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.81"
    }
  }
}

resource "aws_ecr_repository" "this" {
  name = var.name

  # Immutable tags: a sha-<commit> tag always means the same bytes, so what
  # was scanned is what runs and rollbacks are trustworthy.
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true # registry-side scan complements Trivy in CI
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = var.tags
}

# Rules are evaluated by priority (lowest first).
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images (failed/partial pushes) after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${var.keep_tagged_count} CI images (sha-*) for rollback"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = var.tag_prefixes
          countType     = "imageCountMoreThan"
          countNumber   = var.keep_tagged_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
