# Worked example for the README migration question.
#
# Suppose the ECR repo was created by hand in the console before this stack
# existed. Uncomment, run `terraform plan`, and confirm the plan says
# "1 to import, 0 to add, 0 to change, 0 to destroy" before applying.
# Delete this block after the import has been applied.
#
# import {
#   to = module.ecr.aws_ecr_repository.this
#   id = "catalog-api"
# }
#
# import {
#   to = module.ecr.aws_ecr_lifecycle_policy.this
#   id = "catalog-api"
# }
