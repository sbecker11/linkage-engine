output "execution_role_arn" {
  description = "ARN of the ECS task execution role."
  value       = aws_iam_role.execution.arn
}

output "execution_role_name" {
  description = "Name of the ECS task execution role."
  value       = aws_iam_role.execution.name
}

output "task_role_arn" {
  description = "ARN of the ECS task role (runtime permissions)."
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Name of the ECS task role."
  value       = aws_iam_role.task.name
}

output "deploy_role_arn" {
  description = "ARN of the GitHub Actions OIDC deploy role."
  value       = aws_iam_role.deploy.arn
}

output "deploy_role_name" {
  description = "Name of the GitHub Actions OIDC deploy role."
  value       = aws_iam_role.deploy.name
}
