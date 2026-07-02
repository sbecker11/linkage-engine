#!/usr/bin/env bash
# deploy/teardown-linkage-engine.sh
#
# Tear down all linkage-engine AWS resources in us-west-1.
# Does NOT touch ecommerce-embedding-service resources.
# Keeps linkage-engine-tfstate / linkage-engine-tflock for future terraform apply.
#
# Usage:
#   ./deploy/teardown-linkage-engine.sh                    # dry-run (default)
#   ./deploy/teardown-linkage-engine.sh --execute          # destroy (no EIP release)
#   ./deploy/teardown-linkage-engine.sh --execute --release-eips  # also release unattached EIPs
#   ./deploy/teardown-linkage-engine.sh --execute --skip-terraform  # resume after partial TF destroy
#
# Always review dry-run output before passing --execute.

set -euo pipefail

REGION="${AWS_REGION:-us-west-1}"
REQUIRED_ACCOUNT="286103606369"
APP="linkage-engine"
TF_DIR="$(cd "$(dirname "$0")/../infra/envs/prod" && pwd)"

RAW_BUCKET="${APP}-raw-${REQUIRED_ACCOUNT}"
LANDING_BUCKET="${APP}-landing-${REQUIRED_ACCOUNT}"
TFSTATE_BUCKET="${APP}-tfstate"
ORPHAN_RDS_CLUSTER="cluster-zmmja6c5ltmeamcu74bvifgfte"

EXECUTE=0
RELEASE_EIPS=0
SKIP_TERRAFORM=0

for arg in "$@"; do
  case "$arg" in
    --execute) EXECUTE=1 ;;
    --release-eips) RELEASE_EIPS=1 ;;
    --skip-terraform) SKIP_TERRAFORM=1 ;;
    --dry-run) EXECUTE=0 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if [ "$RELEASE_EIPS" -eq 1 ] && [ "$EXECUTE" -eq 0 ]; then
  echo "ERROR: --release-eips requires --execute" >&2
  exit 1
fi

MODE="DRY-RUN"
[ "$EXECUTE" -eq 1 ] && MODE="EXECUTE"

log()  { echo "▶ $*"; }
dry()  { echo "  [dry-run] $*"; }
run()  {
  if [ "$EXECUTE" -eq 1 ]; then
    echo "  → $*"
    eval "$@"
  else
    dry "$*"
  fi
}

section() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $*"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

confirm_account() {
  local account
  account=$(aws sts get-caller-identity --query Account --output text)
  if [ "$account" != "$REQUIRED_ACCOUNT" ]; then
    echo "ERROR: AWS account is ${account}, expected ${REQUIRED_ACCOUNT}. Aborting." >&2
    exit 1
  fi
  echo "✓ AWS account ${account} (${REGION})"
}

# ── Phase 0: inventory ───────────────────────────────────────────────────────

print_inventory() {
  section "Inventory (linkage-engine only)"
  echo "ECS clusters:"
  aws ecs list-clusters --region "$REGION" \
    --query "clusterArns[?contains(@, \`${APP}\`)]" --output text | tr '\t' '\n' | sed 's/^/  /'
  echo "RDS clusters:"
  aws rds describe-db-clusters --region "$REGION" \
    --query "DBClusters[?contains(DBClusterIdentifier, \`linkage\`) || DBClusterIdentifier==\`${ORPHAN_RDS_CLUSTER}\`].[DBClusterIdentifier,Status]" \
    --output text | sed 's/^/  /' || true
  echo "ALBs:"
  aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, \`${APP}\`)].LoadBalancerName" \
    --output text | tr '\t' '\n' | sed 's/^/  /'
  echo "WAF ACLs:"
  aws wafv2 list-web-acls --region "$REGION" --scope REGIONAL \
    --query "WebACLs[?contains(Name, \`linkage\`)].Name" --output text | tr '\t' '\n' | sed 's/^/  /'
  echo "Lambdas:"
  aws lambda list-functions --region "$REGION" \
    --query "Functions[?contains(FunctionName, \`${APP}\`)].FunctionName" \
    --output text | tr '\t' '\n' | sed 's/^/  /'
  echo "S3 buckets (data — tfstate preserved):"
  for b in "$RAW_BUCKET" "$LANDING_BUCKET"; do
    if aws s3api head-bucket --bucket "$b" 2>/dev/null; then
      echo "  ${b}"
    fi
  done
  echo "Secrets:"
  aws secretsmanager list-secrets --region "$REGION" \
    --filters Key=name,Values="$APP" \
    --query 'SecretList[].Name' --output text | tr '\t' '\n' | sed 's/^/  /'
  echo "ECR:"
  aws ecr describe-repositories --region "$REGION" --repository-names "$APP" \
    --query 'repositories[0].repositoryName' --output text 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  echo "CloudWatch alarms (le-* / linkage-engine-*):"
  aws cloudwatch describe-alarms --region "$REGION" \
    --query "MetricAlarms[?starts_with(AlarmName, \`le-\`) || starts_with(AlarmName, \`${APP}-\`)].AlarmName" \
    --output text | tr '\t' '\n' | sed 's/^/  /'
  echo "Log groups containing linkage-engine:"
  aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "/" \
    --query "logGroups[?contains(logGroupName, \`${APP}\`)].logGroupName" \
    --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/  /' || true
  for prefix in "/ecs/${APP}" "/aws/lambda/${APP}"; do
    aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$prefix" \
      --query 'logGroups[].logGroupName' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/  /'
  done
  echo "Elastic IPs in ${REGION} (all — review before release):"
  aws ec2 describe-addresses --region "$REGION" \
    --query 'Addresses[].[PublicIp,AllocationId,AssociationId,ServiceManaged]' \
    --output table
  echo ""
  echo "Preserved (not deleted): ${TFSTATE_BUCKET}, linkage-engine-tflock"
}

# ── Phase 1: Terraform destroy ───────────────────────────────────────────────

terraform_destroy() {
  if [ "$SKIP_TERRAFORM" -eq 1 ]; then
    section "Phase 1 — Terraform destroy (skipped)"
    echo "  --skip-terraform set; running orphan sweep only."
    return
  fi
  section "Phase 1 — Terraform destroy (${TF_DIR})"
  run "cd \"${TF_DIR}\" && terraform init -input=false"
  if [ "$EXECUTE" -eq 1 ]; then
    log "terraform plan -destroy"
    cd "$TF_DIR" && terraform plan -destroy -input=false -no-color
    log "terraform destroy -auto-approve"
    cd "$TF_DIR" && terraform destroy -auto-approve -input=false -no-color
  else
    log "terraform plan -destroy (dry-run)"
    cd "$TF_DIR" && terraform init -input=false > /dev/null
    cd "$TF_DIR" && terraform plan -destroy -input=false -no-color
  fi
}

# ── Phase 2: orphan sweep ────────────────────────────────────────────────────

delete_orphan_rds() {
  section "Phase 2a — Orphan RDS cluster ${ORPHAN_RDS_CLUSTER}"
  if ! aws rds describe-db-clusters --region "$REGION" \
      --db-cluster-identifier "$ORPHAN_RDS_CLUSTER" &>/dev/null; then
    echo "  (not found — skip)"
    return
  fi
  local protection
  protection=$(aws rds describe-db-clusters --region "$REGION" \
    --db-cluster-identifier "$ORPHAN_RDS_CLUSTER" \
    --query 'DBClusters[0].DeletionProtection' --output text)
  if [ "$protection" = "True" ]; then
    run "aws rds modify-db-cluster --region ${REGION} --db-cluster-identifier ${ORPHAN_RDS_CLUSTER} --no-deletion-protection"
  fi
  local instances
  instances=$(aws rds describe-db-instances --region "$REGION" \
    --query "DBInstances[?DBClusterIdentifier==\`${ORPHAN_RDS_CLUSTER}\`].DBInstanceIdentifier" \
    --output text)
  for inst in $instances; do
    run "aws rds delete-db-instance --region ${REGION} --db-instance-identifier ${inst} --skip-final-snapshot"
    if [ "$EXECUTE" -eq 1 ]; then
      aws rds wait db-instance-deleted --region "$REGION" --db-instance-identifier "$inst" || true
    fi
  done
  run "aws rds delete-db-cluster --region ${REGION} --db-cluster-identifier ${ORPHAN_RDS_CLUSTER} --skip-final-snapshot"
}

delete_lambda_pipeline() {
  section "Phase 2b — Lambda pipeline (provision-lambda.sh resources)"
  local funcs=(
    "${APP}-ingestor"
    "${APP}-validate"
    "${APP}-store"
    "${APP}-gap-publisher"
  )
  local roles=(
    "${APP}-ingestor-role"
    "${APP}-validate-role"
    "${APP}-store-role"
    "${APP}-uploader-role"
    "${APP}-gap-publisher-role"
  )

  # S3 notifications must be cleared before bucket delete
  for bucket in "$RAW_BUCKET" "$LANDING_BUCKET"; do
    if aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
      run "aws s3api put-bucket-notification-configuration --region ${REGION} --bucket ${bucket} --notification-configuration '{}'"
      run "aws s3api delete-bucket-policy --bucket ${bucket}"
    fi
  done

  # EventBridge gap-publisher schedule (if present)
  if aws events describe-rule --region "$REGION" --name "${APP}-gap-publisher-schedule" &>/dev/null; then
    run "aws events remove-targets --region ${REGION} --rule ${APP}-gap-publisher-schedule --ids gap-publisher"
    run "aws events delete-rule --region ${REGION} --name ${APP}-gap-publisher-schedule"
  fi

  for fn in "${funcs[@]}"; do
    if aws lambda get-function --region "$REGION" --function-name "$fn" &>/dev/null; then
      run "aws lambda delete-function --region ${REGION} --function-name ${fn}"
    fi
  done

  local dlq_url
  dlq_url=$(aws sqs get-queue-url --region "$REGION" --queue-name "${APP}-store-dlq" \
    --query 'QueueUrl' --output text 2>/dev/null || echo "")
  if [ -n "$dlq_url" ]; then
    run "aws sqs delete-queue --region ${REGION} --queue-url ${dlq_url}"
  fi

  for role in "${roles[@]}"; do
    if aws iam get-role --role-name "$role" &>/dev/null; then
      if [ "$EXECUTE" -eq 1 ]; then
        echo "  → detach/delete IAM policies on ${role}"
        aws iam list-attached-role-policies --role-name "$role" \
          --query 'AttachedPolicies[].PolicyArn' --output text | tr '\t' '\n' | while read -r arn; do
          [ -n "$arn" ] && aws iam detach-role-policy --role-name "$role" --policy-arn "$arn"
        done
        aws iam list-role-policies --role-name "$role" \
          --query 'PolicyNames[]' --output text | tr '\t' '\n' | while read -r pname; do
          [ -n "$pname" ] && aws iam delete-role-policy --role-name "$role" --policy-name "$pname"
        done
        aws iam delete-role --role-name "$role"
      else
        dry "detach policies and delete IAM role ${role}"
      fi
    fi
  done

  run "aws cloudwatch delete-dashboards --region ${REGION} --dashboard-names ${APP}-ops"
}

force_delete_secrets() {
  section "Phase 2c — Secrets Manager (linkage-engine*)"
  local names
  names=$(aws secretsmanager list-secrets --region "$REGION" \
    --filters Key=name,Values="$APP" \
    --query 'SecretList[].Name' --output text 2>/dev/null || echo "")
  for name in $names; do
    run "aws secretsmanager delete-secret --region ${REGION} --secret-id ${name} --force-delete-without-recovery"
  done
  if [ -z "$names" ]; then echo "  (none found)"; fi
}

delete_monitoring_artifacts() {
  section "Phase 2d — CloudWatch alarms and log groups"
  local alarms
  alarms=$(aws cloudwatch describe-alarms --region "$REGION" \
    --query "MetricAlarms[?starts_with(AlarmName, \`le-\`) || starts_with(AlarmName, \`${APP}-\`)].AlarmName" \
    --output text 2>/dev/null || echo "")
  for alarm in $alarms; do
    run "aws cloudwatch delete-alarms --region ${REGION} --alarm-names ${alarm}"
  done
  if [ -z "$alarms" ]; then echo "  (no matching alarms)"; fi

  local groups
  groups=$(aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "/" \
    --query "logGroups[?contains(logGroupName, \`${APP}\`)].logGroupName" \
    --output text 2>/dev/null || echo "")
  for lg in $groups; do
    [ -z "$lg" ] && continue
    run "aws logs delete-log-group --region ${REGION} --log-group-name ${lg}"
  done
  if [ -z "$groups" ]; then echo "  (no matching log groups)"; fi
}

empty_and_delete_bucket() {
  local bucket=$1
  section "Phase 2e — Empty and delete s3://${bucket}"
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "  (not found — skip)"
    return
  fi
  if [ "$EXECUTE" -eq 1 ]; then
    echo "  → emptying all object versions in ${bucket}"
    local key_marker version_marker
    key_marker=""
    version_marker=""
    while true; do
      local resp
      resp=$(aws s3api list-object-versions --bucket "$bucket" \
        ${key_marker:+--key-marker "$key_marker"} \
        ${version_marker:+--version-id-marker "$version_marker"} \
        --output json)
      echo "$resp" | python3 -c "
import json, sys, subprocess
data = json.load(sys.stdin)
bucket = sys.argv[1]
region = sys.argv[2]
items = (data.get('Versions') or []) + (data.get('DeleteMarkers') or [])
for o in items:
    subprocess.run([
        'aws', 's3api', 'delete-object', '--region', region,
        '--bucket', bucket, '--key', o['Key'], '--version-id', o['VersionId'],
    ], check=True)
" "$bucket" "$REGION"
      if [ "$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print('true' if d.get('IsTruncated') else 'false')")" != "true" ]; then
        break
      fi
      key_marker=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('NextKeyMarker') or '')")
      version_marker=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('NextVersionIdMarker') or '')")
    done
    aws s3 rm "s3://${bucket}" --recursive 2>/dev/null || true
    aws s3api delete-bucket --bucket "$bucket" --region "$REGION"
  else
    dry "empty all versions and delete bucket ${bucket}"
  fi
}

delete_ecr_if_exists() {
  section "Phase 2f — ECR repository ${APP}"
  if aws ecr describe-repositories --region "$REGION" --repository-names "$APP" &>/dev/null; then
    run "aws ecr delete-repository --region ${REGION} --repository-name ${APP} --force"
  else
    echo "  (not found — likely removed by terraform)"
  fi
}

list_and_maybe_release_eips() {
  section "Phase 2g — Elastic IPs"
  local unattached
  unattached=$(aws ec2 describe-addresses --region "$REGION" \
    --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' --output text)
  if [ -z "$unattached" ]; then
    echo "  No unattached EIPs in ${REGION}."
    echo "  (All current EIPs are associated — likely ALB-managed; TF destroy releases them.)"
    return
  fi
  echo "  Unattached EIPs:"
  echo "$unattached" | sed 's/^/    /'
  if [ "$RELEASE_EIPS" -eq 1 ]; then
    echo "$unattached" | while read -r alloc ip; do
      run "aws ec2 release-address --region ${REGION} --allocation-id ${alloc}"
    done
  else
    echo ""
    echo "  EIP release skipped. To release unattached EIPs after review:"
    echo "    ./deploy/teardown-linkage-engine.sh --execute --release-eips"
  fi
}

verify_teardown() {
  section "Phase 3 — Verification"
  local found=0
  check() {
    local label=$1
    shift
    local out
    out=$("$@" 2>/dev/null || true)
    if [ -n "$out" ] && [ "$out" != "None" ]; then
      echo "  STILL PRESENT — ${label}:"
      echo "$out" | sed 's/^/    /'
      found=1
    else
      echo "  ✓ ${label}: clear"
    fi
  }
  check "ECS clusters" aws ecs list-clusters --region "$REGION" \
    --query "clusterArns[?contains(@, \`${APP}\`)]" --output text
  check "RDS clusters" aws rds describe-db-clusters --region "$REGION" \
    --query "DBClusters[?contains(DBClusterIdentifier, \`linkage\`) || DBClusterIdentifier==\`${ORPHAN_RDS_CLUSTER}\`].DBClusterIdentifier" \
    --output text
  check "ALBs" aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, \`${APP}\`)].LoadBalancerName" --output text
  check "WAF ACLs" aws wafv2 list-web-acls --region "$REGION" --scope REGIONAL \
    --query "WebACLs[?contains(Name, \`linkage\`)].Name" --output text
  check "Lambdas" aws lambda list-functions --region "$REGION" \
    --query "Functions[?contains(FunctionName, \`${APP}\`)].FunctionName" --output text
  check "data S3 buckets" bash -c "
    for b in ${RAW_BUCKET} ${LANDING_BUCKET}; do
      aws s3api head-bucket --bucket \$b 2>/dev/null && echo \$b
    done"
  check "ECR" aws ecr describe-repositories --region "$REGION" --repository-names "$APP" \
    --query 'repositories[0].repositoryName' --output text
  echo ""
  echo "Preserved: s3://${TFSTATE_BUCKET}, DynamoDB linkage-engine-tflock"
  echo ""
  echo "Billing note: IPv4 addresses, CloudWatch log retention, and any final"
  echo "RDS snapshot storage can take 24–48h to stop accruing charges. Recheck"
  echo "AWS Cost Explorer in a couple of days."
  [ "$found" -eq 0 ] && echo "" && echo "✅ linkage-engine teardown verification passed."
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "linkage-engine teardown — mode: ${MODE}"
confirm_account
print_inventory

terraform_destroy
delete_orphan_rds
delete_lambda_pipeline
force_delete_secrets
delete_monitoring_artifacts
empty_and_delete_bucket "$RAW_BUCKET"
empty_and_delete_bucket "$LANDING_BUCKET"
delete_ecr_if_exists
list_and_maybe_release_eips

if [ "$EXECUTE" -eq 1 ]; then
  verify_teardown
else
  section "Dry-run complete — awaiting approval"
  echo "  No resources were modified."
  echo "  Review the inventory and terraform destroy plan above."
  echo "  Preserved: s3://${TFSTATE_BUCKET}, DynamoDB linkage-engine-tflock"
  echo ""
  echo "  To destroy:"
  echo "    ./deploy/teardown-linkage-engine.sh --execute"
  echo ""
  echo "  To also release unattached EIPs (after reviewing the EIP table):"
  echo "    ./deploy/teardown-linkage-engine.sh --execute --release-eips"
fi
