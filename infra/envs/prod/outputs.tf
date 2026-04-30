output "ecr_repository_url" {
  description = "ECR repository URL — use as the Docker image registry base."
  value       = module.ecr.repository_url
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer."
  value       = module.alb.alb_dns_name
}

output "alb_url" {
  description = "Full HTTP URL of the ALB."
  value       = "http://${module.alb.alb_dns_name}"
}

output "aurora_endpoint" {
  description = "Aurora cluster writer endpoint."
  value       = module.aurora.cluster_endpoint
}

output "secret_arn" {
  description = "ARN of the Secrets Manager runtime secret."
  value       = module.secrets.secret_arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = module.ecs.service_name
}

output "deploy_role_arn" {
  description = "ARN of the GitHub Actions OIDC deploy role — set as GitHub secret AWS_DEPLOY_ROLE_ARN."
  value       = module.iam.deploy_role_arn
}

output "next_steps" {
  description = "Post-apply instructions."
  value       = <<-EOT
    ✅  Production environment ready.

    1. Set GitHub repository secret:
         Name:  AWS_DEPLOY_ROLE_ARN
         Value: ${module.iam.deploy_role_arn}

    2. Trigger the deploy workflow:
         GitHub → Actions → deploy-ecr-ecs → Run workflow

    3. After first deploy, seed the database:
         BASE_URL=http://${module.alb.alb_dns_name} ./demo/seed-data.sh

    4. Open the chord diagram:
         http://${module.alb.alb_dns_name}/chord-diagram.html
  EOT
}
