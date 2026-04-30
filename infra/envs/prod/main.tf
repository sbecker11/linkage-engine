# ── Existing VPC and subnets (default VPC — not managed by Terraform) ──────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_caller_identity" "current" {}

# ── Credentials generated once, stable across applies ─────────────────────────

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "ingest_api_key" {
  length  = 64
  special = false
}

# ── Modules ────────────────────────────────────────────────────────────────────

module "ecr" {
  source = "../../modules/ecr"
  app    = var.app
  tags   = var.tags
}

module "networking" {
  source         = "../../modules/networking"
  app            = var.app
  vpc_id         = data.aws_vpc.default.id
  container_port = 8080
  tags           = var.tags
}

module "monitoring" {
  source                  = "../../modules/monitoring"
  app                     = var.app
  aws_region              = var.aws_region
  cluster_name            = module.ecs.cluster_name
  service_name            = module.ecs.service_name
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  db_cluster_identifier   = "${var.app}-aurora"
  alert_email             = var.alert_email
  monthly_budget_usd      = var.monthly_budget_usd
  aws_account_id          = data.aws_caller_identity.current.account_id
  tags                    = var.tags
}

module "aurora" {
  source       = "../../modules/aurora"
  app          = var.app
  db_sg_id     = module.networking.db_sg_id
  subnet_ids   = data.aws_subnets.default.ids
  db_password  = random_password.db.result
  min_capacity = var.aurora_min_capacity
  max_capacity = var.aurora_max_capacity
  tags         = var.tags
}

module "secrets" {
  source         = "../../modules/secrets"
  app            = var.app
  db_url         = "jdbc:postgresql://${module.aurora.cluster_endpoint}:5432/${module.aurora.db_name}"
  db_username    = module.aurora.db_username
  db_password    = random_password.db.result
  ingest_api_key = random_password.ingest_api_key.result
  tags           = var.tags
}

module "iam" {
  source             = "../../modules/iam"
  app                = var.app
  secret_arn         = module.secrets.secret_arn
  ecr_repository_arn = module.ecr.repository_arn
  aws_account_id     = data.aws_caller_identity.current.account_id
  github_repo        = var.github_repo
  tags               = var.tags
}

module "acm" {
  count       = var.domain_name != "" ? 1 : 0
  source      = "../../modules/acm"
  domain_name = var.domain_name
  tags        = var.tags
}

module "alb" {
  source         = "../../modules/alb"
  app            = var.app
  vpc_id         = data.aws_vpc.default.id
  subnet_ids     = data.aws_subnets.default.ids
  alb_sg_id      = module.networking.alb_sg_id
  container_port = 8080
  cert_arn       = var.domain_name != "" ? module.acm[0].cert_arn : ""
  tags           = var.tags
}

module "waf" {
  source  = "../../modules/waf"
  app     = var.app
  alb_arn = module.alb.alb_arn
  tags    = var.tags
}

module "ecs" {
  source             = "../../modules/ecs"
  app                = var.app
  aws_region         = var.aws_region
  execution_role_arn = module.iam.execution_role_arn
  task_role_arn      = module.iam.task_role_arn
  secret_arn         = module.secrets.secret_arn
  ecr_image_uri      = var.ecr_image_uri != "" ? var.ecr_image_uri : "${module.ecr.repository_url}:latest"
  ecs_sg_id          = module.networking.ecs_sg_id
  subnet_ids         = data.aws_subnets.default.ids
  target_group_arn   = module.alb.target_group_arn
  log_group_name     = module.monitoring.log_group_name
  desired_count      = var.ecs_desired_count
  tags               = var.tags
}
