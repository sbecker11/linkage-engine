output "log_group_name" {
  description = "CloudWatch log group name for ECS task logs."
  value       = aws_cloudwatch_log_group.ecs.name
}

output "sns_topic_arn" {
  description = "ARN of the SNS alerts topic."
  value       = aws_sns_topic.alerts.arn
}

output "sns_topic_name" {
  description = "Name of the SNS alerts topic."
  value       = aws_sns_topic.alerts.name
}
