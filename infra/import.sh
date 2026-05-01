#!/usr/bin/env bash
# infra/import.sh
#
# Imports existing AWS resources into Terraform state so that the first
# "terraform apply" does not try to recreate them.
#
# Run from infra/envs/prod/ BEFORE terraform apply:
#
#   cd infra/envs/prod
#   bash ../../import.sh
#   terraform plan          # should show no changes (or only minor drift)
#   terraform apply         # safe to run — idempotent
#
# terraform init is run automatically by this script.
#
# Prerequisites:
#   - AWS CLI v2 configured with sufficient IAM permissions
#   - Terraform initialized in infra/envs/prod/
#   - jq

set -euo pipefail

REGION="${AWS_REGION:-us-west-1}"
APP="linkage-engine"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Importing existing ${APP} resources into Terraform state"
echo "  Region: ${REGION}   Account: ${ACCOUNT_ID}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "▶ terraform init"
terraform init -input=false
echo "  ✓ initialized"

tf_import() {
  local address="$1"
  local id="$2"
  echo ""
  echo "▶ terraform import ${address}"
  echo "  ID: ${id}"
  # -lock=false: this script is a sequential single-user operation;
  # skipping the DynamoDB lock avoids stale-lock contention between
  # rapid sequential imports.
  terraform import -lock=false "${address}" "${id}" && echo "  ✓ imported" || echo "  ⚠ skipped (may already be in state)"
}

# ── ECR ────────────────────────────────────────────────────────────────────────
tf_import "module.ecr.aws_ecr_repository.main" "${APP}"

# ── Security groups ────────────────────────────────────────────────────────────
ALB_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${APP}-alb-sg" "Name=vpc-id,Values=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
ECS_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${APP}-ecs-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
DB_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${APP}-db-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")

[ -n "$ALB_SG_ID" ] && [ "$ALB_SG_ID" != "None" ] && tf_import "module.networking.aws_security_group.alb" "$ALB_SG_ID"
[ -n "$ECS_SG_ID" ] && [ "$ECS_SG_ID" != "None" ] && tf_import "module.networking.aws_security_group.ecs" "$ECS_SG_ID"
[ -n "$DB_SG_ID"  ] && [ "$DB_SG_ID"  != "None" ] && tf_import "module.networking.aws_security_group.db"  "$DB_SG_ID"

# ── Security group rules (standalone resources — must import or apply fails with Duplicate) ──
# Looks up each rule by group-id + direction + port so the script stays idempotent.
_sgr() {
  local sg_id="$1" egress="$2" proto="$3" from="$4" to="$5" peer="$6"
  local filter="Name=group-id,Values=${sg_id} Name=is-egress,Values=${egress}"
  [ -n "$proto"  ] && filter="${filter} Name=ip-protocol,Values=${proto}"
  [ -n "$from"   ] && filter="${filter} Name=from-port,Values=${from}"
  [ -n "$to"     ] && filter="${filter} Name=to-port,Values=${to}"
  [ -n "$peer"   ] && filter="${filter} Name=cidr-ipv4,Values=${peer}"
  aws ec2 describe-security-group-rules --region "$REGION" \
    --filters $filter \
    --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text 2>/dev/null || echo ""
}

if [ -n "$ALB_SG_ID" ] && [ "$ALB_SG_ID" != "None" ]; then
  R=$(  _sgr "$ALB_SG_ID" false tcp 80  80  "0.0.0.0/0") && [ -n "$R" ] && [ "$R" != "None" ] && tf_import "module.networking.aws_vpc_security_group_ingress_rule.alb_http"  "$R"
  R=$(  _sgr "$ALB_SG_ID" false tcp 443 443 "0.0.0.0/0") && [ -n "$R" ] && [ "$R" != "None" ] && tf_import "module.networking.aws_vpc_security_group_ingress_rule.alb_https" "$R"
  R=$(  _sgr "$ALB_SG_ID" true  -1  ""  ""  "0.0.0.0/0") && [ -n "$R" ] && [ "$R" != "None" ] && tf_import "module.networking.aws_vpc_security_group_egress_rule.alb_egress"  "$R"
fi
if [ -n "$ECS_SG_ID" ] && [ "$ECS_SG_ID" != "None" ]; then
  R=$(  _sgr "$ECS_SG_ID" false tcp 8080 8080 "") && [ -n "$R" ] && [ "$R" != "None" ] && tf_import "module.networking.aws_vpc_security_group_ingress_rule.ecs_from_alb" "$R"
  R=$(  _sgr "$ECS_SG_ID" true  -1  ""   ""   "0.0.0.0/0") && [ -n "$R" ] && [ "$R" != "None" ] && tf_import "module.networking.aws_vpc_security_group_egress_rule.ecs_egress"  "$R"
fi
if [ -n "$DB_SG_ID" ] && [ "$DB_SG_ID" != "None" ]; then
  R=$(  _sgr "$DB_SG_ID"  false tcp 5432 5432 "") && [ -n "$R" ] && [ "$R" != "None" ] && tf_import "module.networking.aws_vpc_security_group_ingress_rule.db_from_ecs" "$R"
fi

# ── Aurora ─────────────────────────────────────────────────────────────────────
tf_import "module.aurora.aws_db_subnet_group.main"         "${APP}-subnet-group"
tf_import "module.aurora.aws_rds_cluster.main"             "${APP}-aurora"
tf_import "module.aurora.aws_rds_cluster_instance.writer"  "${APP}-aurora-writer"

# ── Secrets Manager ────────────────────────────────────────────────────────────
SECRET_ARN=$(aws secretsmanager describe-secret --region "$REGION" \
  --secret-id "${APP}/runtime" --query 'ARN' --output text 2>/dev/null || echo "")
[ -n "$SECRET_ARN" ] && [ "$SECRET_ARN" != "None" ] && \
  tf_import "module.secrets.aws_secretsmanager_secret.runtime" "$SECRET_ARN"

# ── IAM ────────────────────────────────────────────────────────────────────────
tf_import "module.iam.aws_iam_role.execution" "${APP}-execution-role"
tf_import "module.iam.aws_iam_role.task"      "${APP}-task-role"
tf_import "module.iam.aws_iam_role.deploy"    "${APP}-github-deploy-role"
tf_import "module.iam.aws_iam_openid_connect_provider.github" \
  "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

# ── CloudWatch log group ───────────────────────────────────────────────────────
tf_import "module.monitoring.aws_cloudwatch_log_group.ecs" "/ecs/${APP}"

# ── ALB ────────────────────────────────────────────────────────────────────────
ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "${APP}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" \
  --names "${APP}-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")

[ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ] && tf_import "module.alb.aws_lb.main"              "$ALB_ARN"
[ -n "$TG_ARN"  ] && [ "$TG_ARN"  != "None" ] && tf_import "module.alb.aws_lb_target_group.app"  "$TG_ARN"

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  HTTP_LISTENER=$(aws elbv2 describe-listeners --region "$REGION" \
    --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text 2>/dev/null || echo "")
  [ -n "$HTTP_LISTENER" ] && [ "$HTTP_LISTENER" != "None" ] && \
    tf_import "module.alb.aws_lb_listener.http" "$HTTP_LISTENER"
fi

# ── WAF ────────────────────────────────────────────────────────────────────────
WAF_ID=$(aws wafv2 list-web-acls --region "$REGION" --scope REGIONAL \
  --query "WebACLs[?Name=='${APP}-rate-limit'].Id | [0]" --output text 2>/dev/null || echo "")
if [ -n "$WAF_ID" ] && [ "$WAF_ID" != "None" ]; then
  tf_import "module.waf.aws_wafv2_web_acl.main" "${WAF_ID}/${APP}-rate-limit/REGIONAL"
fi

# ── ECS ────────────────────────────────────────────────────────────────────────
tf_import "module.ecs.aws_ecs_cluster.main"  "${APP}-cluster"
tf_import "module.ecs.aws_ecs_service.main"  "${APP}-cluster/${APP}-service"

# ── Monitoring ─────────────────────────────────────────────────────────────────
SNS_ARN=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?ends_with(TopicArn,'${APP}-alerts')].TopicArn | [0]" \
  --output text 2>/dev/null || echo "")
[ -n "$SNS_ARN" ] && [ "$SNS_ARN" != "None" ] && \
  tf_import "module.monitoring.aws_sns_topic.alerts" "$SNS_ARN"

for alarm in "${APP}-ecs-memory-high" "${APP}-aurora-storage-low" "${APP}-alb-healthy-hosts" "${APP}-ecs-tasks-running"; do
  tf_import "module.monitoring.aws_cloudwatch_metric_alarm.${alarm#${APP}-}" "$alarm" 2>/dev/null || true
done

# Budget (uses account-level resource)
tf_import "module.monitoring.aws_budgets_budget.monthly" \
  "${ACCOUNT_ID}:${APP}-monthly-budget"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Import complete. Run 'terraform plan' to verify no-diff."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
