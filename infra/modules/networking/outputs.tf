output "alb_sg_id" {
  description = "Security group ID for the Application Load Balancer."
  value       = aws_security_group.alb.id
}

output "ecs_sg_id" {
  description = "Security group ID for ECS Fargate tasks."
  value       = aws_security_group.ecs.id
}

output "db_sg_id" {
  description = "Security group ID for the Aurora database cluster."
  value       = aws_security_group.db.id
}
