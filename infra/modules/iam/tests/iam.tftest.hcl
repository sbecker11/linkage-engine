# IAM module tests
#
# Uses mock_provider — no AWS credentials required.
# Run from infra/modules/iam/:
#   terraform init && terraform test

mock_provider "aws" {}

variables {
  app                = "linkage-engine"
  secret_arn         = "arn:aws:secretsmanager:us-west-1:286103606369:secret:linkage-engine/runtime-test"
  ecr_repository_arn = "arn:aws:ecr:us-west-1:286103606369:repository/linkage-engine"
  aws_account_id     = "286103606369"
  github_repo        = "sbecker11/linkage-engine"
  tags = {
    App = "linkage-engine"
    Env = "prod"
  }
}

run "role_names_follow_convention" {
  command = plan

  assert {
    condition     = aws_iam_role.execution.name == "linkage-engine-execution-role"
    error_message = "Execution role name must be '<app>-execution-role'."
  }

  assert {
    condition     = aws_iam_role.task.name == "linkage-engine-task-role"
    error_message = "Task role name must be '<app>-task-role'."
  }

  assert {
    condition     = aws_iam_role.deploy.name == "linkage-engine-github-deploy-role"
    error_message = "Deploy role name must be '<app>-github-deploy-role'."
  }
}

run "execution_role_trusts_ecs_tasks" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.execution.assume_role_policy).Statement[0].Principal.Service
      == "ecs-tasks.amazonaws.com"
    )
    error_message = "Execution role must trust ecs-tasks.amazonaws.com."
  }
}

run "task_role_trusts_ecs_tasks" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.task.assume_role_policy).Statement[0].Principal.Service
      == "ecs-tasks.amazonaws.com"
    )
    error_message = "Task role must trust ecs-tasks.amazonaws.com."
  }
}

run "execution_secrets_policy_references_correct_secret" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role_policy.execution_secrets.policy).Statement[0].Resource
      == "arn:aws:secretsmanager:us-west-1:286103606369:secret:linkage-engine/runtime-test"
    )
    error_message = "Execution secrets policy must reference the provided secret ARN."
  }
}

run "task_bedrock_policy_allows_invoke_model" {
  command = plan

  assert {
    condition = contains(
      jsondecode(aws_iam_role_policy.task_bedrock.policy).Statement[0].Action,
      "bedrock:InvokeModel"
    )
    error_message = "Task role must allow bedrock:InvokeModel."
  }

  assert {
    condition = contains(
      jsondecode(aws_iam_role_policy.task_bedrock.policy).Statement[0].Action,
      "bedrock:InvokeModelWithResponseStream"
    )
    error_message = "Task role must allow bedrock:InvokeModelWithResponseStream."
  }
}

run "deploy_role_trusts_github_oidc" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Principal.Federated
      == "arn:aws:iam::286103606369:oidc-provider/token.actions.githubusercontent.com"
    )
    error_message = "Deploy role must federate with the GitHub Actions OIDC provider."
  }
}

run "deploy_role_scoped_to_correct_github_repo" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.deploy.assume_role_policy)
        .Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"]
      == "repo:sbecker11/linkage-engine:*"
    )
    error_message = "Deploy role condition must be scoped to the correct GitHub repo."
  }
}

run "deploy_policy_allows_ecr_push_actions" {
  # apply needed: policy JSON includes computed execution/task role ARNs
  command = apply

  assert {
    condition = contains(
      jsondecode(aws_iam_role_policy.deploy.policy).Statement[1].Action,
      "ecr:PutImage"
    )
    error_message = "Deploy policy must allow ecr:PutImage."
  }
}

run "deploy_policy_allows_ecs_update_service" {
  # apply needed: policy JSON includes computed execution/task role ARNs
  command = apply

  assert {
    condition = contains(
      jsondecode(aws_iam_role_policy.deploy.policy).Statement[2].Action,
      "ecs:UpdateService"
    )
    error_message = "Deploy policy must allow ecs:UpdateService."
  }
}

run "output_role_names_match_resources" {
  command = plan

  assert {
    condition     = output.execution_role_name == "linkage-engine-execution-role"
    error_message = "execution_role_name output must match the resource."
  }

  assert {
    condition     = output.task_role_name == "linkage-engine-task-role"
    error_message = "task_role_name output must match the resource."
  }

  assert {
    condition     = output.deploy_role_name == "linkage-engine-github-deploy-role"
    error_message = "deploy_role_name output must match the resource."
  }
}
