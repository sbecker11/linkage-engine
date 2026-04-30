output "state_bucket" {
  description = "S3 bucket name for Terraform remote state."
  value       = aws_s3_bucket.tfstate.bucket
}

output "lock_table" {
  description = "DynamoDB table name for Terraform state locking."
  value       = aws_dynamodb_table.tflock.name
}

output "aws_region" {
  description = "AWS region where the state resources were created."
  value       = var.aws_region
}

output "backend_config" {
  description = "Copy this block into infra/envs/prod/versions.tf to enable remote state."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.tfstate.bucket}"
        key            = "prod/terraform.tfstate"
        region         = "${var.aws_region}"
        dynamodb_table = "${aws_dynamodb_table.tflock.name}"
        encrypt        = true
      }
    }
  EOT
}
