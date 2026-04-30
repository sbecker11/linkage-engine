locals {
  ecs_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  oidc_provider     = "token.actions.githubusercontent.com"
  oidc_provider_arn = "arn:aws:iam::${var.aws_account_id}:oidc-provider/${local.oidc_provider}"
}

# ── GitHub OIDC provider ───────────────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://${local.oidc_provider}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = var.tags
}

# ── ECS task execution role ────────────────────────────────────────────────────
# Allows ECS to pull images from ECR and inject secrets from Secrets Manager.

resource "aws_iam_role" "execution" {
  name               = "${var.app}-execution-role"
  assume_role_policy = local.ecs_trust_policy
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_ecs" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "SecretsAccess"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.secret_arn
    }]
  })
}

# ── ECS task role ──────────────────────────────────────────────────────────────
# Runtime permissions for the application: Bedrock inference + CloudWatch metrics.

resource "aws_iam_role" "task" {
  name               = "${var.app}-task-role"
  assume_role_policy = local.ecs_trust_policy
  tags               = var.tags
}

resource "aws_iam_role_policy" "task_bedrock" {
  name = "BedrockAccess"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ]
      Resource = "*"
    }]
  })
}

# ── GitHub Actions OIDC deploy role ───────────────────────────────────────────
# Federated identity for CI: push images to ECR and trigger ECS/Terraform updates.

resource "aws_iam_role" "deploy" {
  name = "${var.app}-github-deploy-role"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "${local.oidc_provider}:sub" = "repo:${var.github_repo}:*"
        }
        StringEquals = {
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "deploy" {
  name = "DeployPolicy"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = var.ecr_repository_arn
      },
      {
        Sid    = "ECSdeploy"
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:UpdateService",
          "ecs:DescribeServices"
        ]
        Resource = "*"
      },
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.app}-tfstate",
          "arn:aws:s3:::${var.app}-tfstate/*"
        ]
      },
      {
        Sid    = "TerraformLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable"
        ]
        Resource = "arn:aws:dynamodb:*:${var.aws_account_id}:table/${var.app}-tflock"
      },
      {
        Sid    = "PassECSRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.execution.arn,
          aws_iam_role.task.arn
        ]
      }
    ]
  })
}
