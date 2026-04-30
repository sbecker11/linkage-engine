output "repository_url" {
  description = "Full ECR repository URL (used as Docker image registry base)."
  value       = aws_ecr_repository.main.repository_url
}

output "repository_arn" {
  description = "ARN of the ECR repository (used in IAM policy Resource fields)."
  value       = aws_ecr_repository.main.arn
}

output "repository_name" {
  description = "Short repository name."
  value       = aws_ecr_repository.main.name
}
