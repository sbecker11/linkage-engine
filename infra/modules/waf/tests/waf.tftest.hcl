# WAF module tests
#
# Uses mock_provider — no AWS credentials required.
# Run from infra/modules/waf/:
#   terraform init && terraform test

mock_provider "aws" {}

variables {
  app        = "linkage-engine"
  alb_arn    = "arn:aws:elasticloadbalancing:us-west-1:286103606369:loadbalancer/app/linkage-engine-alb/test"
  rate_limit = 500
}

run "web_acl_name_follows_convention" {
  command = plan

  assert {
    condition     = aws_wafv2_web_acl.main.name == "linkage-engine-rate-limit"
    error_message = "WAF WebACL name must be '<app>-rate-limit'."
  }
}

run "web_acl_scope_is_regional" {
  command = plan

  assert {
    condition     = aws_wafv2_web_acl.main.scope == "REGIONAL"
    error_message = "WAF WebACL scope must be REGIONAL (for ALB association)."
  }
}

run "default_action_is_allow" {
  command = plan

  assert {
    condition     = length(aws_wafv2_web_acl.main.default_action[0].allow) == 1
    error_message = "WAF default action must be allow (rate rule blocks offenders explicitly)."
  }
}

run "rate_rule_has_correct_limit" {
  command = plan

  assert {
    condition = (
      one(one(one(aws_wafv2_web_acl.main.rule).statement).rate_based_statement).limit == 500
    )
    error_message = "Rate rule limit must match var.rate_limit (default 500)."
  }
}

run "rate_rule_aggregates_by_ip" {
  command = plan

  assert {
    condition = (
      one(one(one(aws_wafv2_web_acl.main.rule).statement).rate_based_statement).aggregate_key_type == "IP"
    )
    error_message = "Rate rule must aggregate by IP address."
  }
}

run "rate_rule_blocks_offenders" {
  command = plan

  assert {
    condition     = length(one(aws_wafv2_web_acl.main.rule).action[0].block) == 1
    error_message = "Rate rule action must be block."
  }
}

run "output_web_acl_name_matches_resource" {
  command = plan

  assert {
    condition     = output.web_acl_name == "linkage-engine-rate-limit"
    error_message = "web_acl_name output must match the resource name."
  }
}

run "custom_rate_limit_is_respected" {
  command = plan

  variables {
    rate_limit = 1000
  }

  assert {
    condition = (
      one(one(one(aws_wafv2_web_acl.main.rule).statement).rate_based_statement).limit == 1000
    )
    error_message = "Custom rate_limit must be reflected in the WAF rule."
  }
}
