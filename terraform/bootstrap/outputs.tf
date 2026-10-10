output "state_bucket_name" {
  description = "Put this in terraform/live/backend.hcl as `bucket`."
  value       = module.state_bucket.bucket_name
}

output "state_bucket_arn" {
  description = "State bucket ARN."
  value       = module.state_bucket.bucket_arn
}
