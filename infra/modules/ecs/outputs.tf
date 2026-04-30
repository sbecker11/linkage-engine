output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.main.arn
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.main.name
}

output "task_family" {
  description = "ECS task definition family name."
  value       = aws_ecs_task_definition.main.family
}

output "task_definition_arn" {
  description = "Full ARN of the latest registered task definition revision."
  value       = aws_ecs_task_definition.main.arn
}
