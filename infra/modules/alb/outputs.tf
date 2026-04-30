output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "ARN of the ALB target group (used in ECS service load_balancer config)."
  value       = aws_lb_target_group.app.arn
}

output "http_listener_arn" {
  description = "ARN of the HTTP :80 listener."
  value       = aws_lb_listener.http.arn
}
