output "secret_arn" {
  description = "ARN of the Secrets Manager secret (used in IAM policies and ECS task definition)."
  value       = aws_secretsmanager_secret.runtime.arn
}

output "secret_name" {
  description = "Name of the Secrets Manager secret."
  value       = aws_secretsmanager_secret.runtime.name
}
