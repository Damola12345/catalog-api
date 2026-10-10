output "bucket_name" {
  description = "Name of the state bucket (use in backend config)."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the state bucket (use in IAM policies)."
  value       = aws_s3_bucket.this.arn
}
