#!/usr/bin/env bash
# deploy/provision-aws.sh
#
# One-shot provisioning script for linkage-engine on ECS Fargate.
# Run this ONCE before the first GitHub Actions deploy.
#
# Prerequisites:
#   - AWS CLI v2 configured (aws sts get-caller-identity must succeed)
#   - jq installed
#   - Sufficient IAM permissions (AdministratorAccess or equivalent)
#
# Usage:
#   chmod +x deploy/provision-aws.sh
#   ./deploy/provision-aws.sh
#
# After this script completes:
#   1. Set GitHub secret AWS_DEPLOY_ROLE_ARN to the OIDC role ARN printed at the end.
#   2. Run the deploy-ecr-ecs workflow from GitHub Actions → Run workflow.

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
REGION="${AWS_REGION:-us-west-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
APP=linkage-engine
CLUSTER="${APP}-cluster"
SERVICE="${APP}-service"
ECR_REPO="${APP}"
SECRET_NAME="${APP}/runtime"
LOG_GROUP="/ecs/${APP}"
DB_NAME="linkage_db"
DB_USER="ancestry"
DB_CLUSTER_ID="${APP}-aurora"
TASK_FAMILY="${APP}"
CONTAINER_PORT=8080

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)

SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=default-for-az,Values=true" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Provisioning ${APP} in ${REGION} (account ${ACCOUNT_ID})"
echo "  VPC: ${VPC_ID}   Subnets: ${SUBNET_IDS}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. ECR repository ──────────────────────────────────────────────────────────
echo ""
echo "▶ 1/10  ECR repository"
if aws ecr describe-repositories --region "$REGION" --repository-names "$ECR_REPO" &>/dev/null; then
  echo "  ✓ already exists"
else
  aws ecr create-repository --region "$REGION" --repository-name "$ECR_REPO" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE
  echo "  ✓ created"
fi
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"

# ── 2. CloudWatch log group ────────────────────────────────────────────────────
echo ""
echo "▶ 2/10  CloudWatch log group ${LOG_GROUP}"
aws logs create-log-group --region "$REGION" --log-group-name "$LOG_GROUP" 2>/dev/null || true
aws logs put-retention-policy --region "$REGION" \
  --log-group-name "$LOG_GROUP" --retention-in-days 30
echo "  ✓ done"

# ── 3. Security groups ─────────────────────────────────────────────────────────
echo ""
echo "▶ 3/10  Security groups"

ALB_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${APP}-alb-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$ALB_SG_ID" = "None" ] || [ -z "$ALB_SG_ID" ]; then
  ALB_SG_ID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "${APP}-alb-sg" \
    --description "ALB security group for ${APP}" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$ALB_SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0
  echo "  ✓ ALB SG created: ${ALB_SG_ID}"
else
  echo "  ✓ ALB SG exists: ${ALB_SG_ID}"
fi

ECS_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${APP}-ecs-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$ECS_SG_ID" = "None" ] || [ -z "$ECS_SG_ID" ]; then
  ECS_SG_ID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "${APP}-ecs-sg" \
    --description "ECS task security group for ${APP}" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$ECS_SG_ID" --protocol tcp --port "$CONTAINER_PORT" \
    --source-group "$ALB_SG_ID"
  echo "  ✓ ECS SG created: ${ECS_SG_ID}"
else
  echo "  ✓ ECS SG exists: ${ECS_SG_ID}"
fi

DB_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${APP}-db-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [ "$DB_SG_ID" = "None" ] || [ -z "$DB_SG_ID" ]; then
  DB_SG_ID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "${APP}-db-sg" \
    --description "Aurora security group for ${APP}" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$DB_SG_ID" --protocol tcp --port 5432 \
    --source-group "$ECS_SG_ID"
  echo "  ✓ DB SG created: ${DB_SG_ID}"
else
  echo "  ✓ DB SG exists: ${DB_SG_ID}"
fi

# ── 4. Aurora PostgreSQL Serverless v2 ────────────────────────────────────────
echo ""
echo "▶ 4/10  Aurora PostgreSQL Serverless v2"
DB_STATUS=$(aws rds describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$DB_CLUSTER_ID" \
  --query 'DBClusters[0].Status' --output text 2>/dev/null || echo "not-found")

if [ "$DB_STATUS" = "not-found" ]; then
  DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
  echo "  Creating Aurora cluster (this takes ~5 minutes)…"

  # DB subnet group
  SUBNET_ID_1=$(echo "$SUBNET_IDS" | cut -d',' -f1)
  SUBNET_ID_2=$(echo "$SUBNET_IDS" | cut -d',' -f2)
  aws rds create-db-subnet-group --region "$REGION" \
    --db-subnet-group-name "${APP}-subnet-group" \
    --db-subnet-group-description "Subnet group for ${APP}" \
    --subnet-ids "$SUBNET_ID_1" "$SUBNET_ID_2" 2>/dev/null || true

  aws rds create-db-cluster \
    --region "$REGION" \
    --db-cluster-identifier "$DB_CLUSTER_ID" \
    --engine aurora-postgresql \
    --engine-version 15.4 \
    --serverless-v2-scaling-configuration MinCapacity=0,MaxCapacity=2 \
    --database-name "$DB_NAME" \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --db-subnet-group-name "${APP}-subnet-group" \
    --vpc-security-group-ids "$DB_SG_ID" \
    --no-deletion-protection \
    --enable-cloudwatch-logs-exports postgresql

  aws rds create-db-instance \
    --region "$REGION" \
    --db-instance-identifier "${DB_CLUSTER_ID}-writer" \
    --db-cluster-identifier "$DB_CLUSTER_ID" \
    --db-instance-class db.serverless \
    --engine aurora-postgresql

  echo "  Waiting for Aurora cluster to become available…"
  aws rds wait db-cluster-available \
    --region "$REGION" \
    --db-cluster-identifier "$DB_CLUSTER_ID"
  echo "  ✓ Aurora cluster ready"
else
  echo "  ✓ Aurora cluster exists (status: ${DB_STATUS})"
  DB_PASSWORD="EXISTING_SECRET_UNCHANGED"
fi

DB_ENDPOINT=$(aws rds describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$DB_CLUSTER_ID" \
  --query 'DBClusters[0].Endpoint' --output text)
DB_URL="jdbc:postgresql://${DB_ENDPOINT}:5432/${DB_NAME}"
echo "  Endpoint: ${DB_ENDPOINT}"

# ── 5. Secrets Manager ────────────────────────────────────────────────────────
echo ""
echo "▶ 5/10  Secrets Manager"
SECRET_EXISTS=$(aws secretsmanager describe-secret --region "$REGION" \
  --secret-id "$SECRET_NAME" --query 'Name' --output text 2>/dev/null || echo "not-found")

if [ "$SECRET_EXISTS" = "not-found" ]; then
  aws secretsmanager create-secret \
    --region "$REGION" \
    --name "$SECRET_NAME" \
    --description "linkage-engine runtime DB credentials" \
    --secret-string "{\"DB_URL\":\"${DB_URL}\",\"DB_USER\":\"${DB_USER}\",\"DB_PASSWORD\":\"${DB_PASSWORD}\"}"
  echo "  ✓ secret created"
else
  echo "  ✓ secret exists — updating DB_URL endpoint"
  CURRENT=$(aws secretsmanager get-secret-value --region "$REGION" \
    --secret-id "$SECRET_NAME" --query SecretString --output text)
  UPDATED=$(echo "$CURRENT" | jq --arg url "$DB_URL" '.DB_URL = $url')
  aws secretsmanager put-secret-value --region "$REGION" \
    --secret-id "$SECRET_NAME" --secret-string "$UPDATED"
fi

SECRET_ARN=$(aws secretsmanager describe-secret --region "$REGION" \
  --secret-id "$SECRET_NAME" --query 'ARN' --output text)
echo "  ARN: ${SECRET_ARN}"

# ── 6. IAM roles ──────────────────────────────────────────────────────────────
echo ""
echo "▶ 6/10  IAM roles"

# ECS task execution role
EXEC_ROLE_NAME="${APP}-execution-role"
EXEC_ROLE_ARN=$(aws iam get-role --role-name "$EXEC_ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "not-found")
if [ "$EXEC_ROLE_ARN" = "not-found" ]; then
  EXEC_ROLE_ARN=$(aws iam create-role \
    --role-name "$EXEC_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},
      "Action":"sts:AssumeRole"}]}' \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  aws iam put-role-policy --role-name "$EXEC_ROLE_NAME" \
    --policy-name SecretsAccess \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{\"Effect\":\"Allow\",
        \"Action\":[\"secretsmanager:GetSecretValue\"],
        \"Resource\":\"${SECRET_ARN}\"}]}"
  echo "  ✓ execution role created: ${EXEC_ROLE_ARN}"
else
  echo "  ✓ execution role exists: ${EXEC_ROLE_ARN}"
fi

# ECS task role (app permissions: Bedrock + S3)
TASK_ROLE_NAME="${APP}-task-role"
TASK_ROLE_ARN=$(aws iam get-role --role-name "$TASK_ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "not-found")
if [ "$TASK_ROLE_ARN" = "not-found" ]; then
  TASK_ROLE_ARN=$(aws iam create-role \
    --role-name "$TASK_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},
      "Action":"sts:AssumeRole"}]}' \
    --query 'Role.Arn' --output text)
  aws iam put-role-policy --role-name "$TASK_ROLE_NAME" \
    --policy-name BedrockAccess \
    --policy-document '{
      "Version":"2012-10-17",
      "Statement":[
        {"Effect":"Allow",
         "Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],
         "Resource":"*"}
      ]}'
  echo "  ✓ task role created: ${TASK_ROLE_ARN}"
else
  echo "  ✓ task role exists: ${TASK_ROLE_ARN}"
fi

# ── 7. ECS cluster ────────────────────────────────────────────────────────────
echo ""
echo "▶ 7/10  ECS cluster"
CLUSTER_ARN=$(aws ecs describe-clusters --region "$REGION" \
  --clusters "$CLUSTER" \
  --query 'clusters[?status==`ACTIVE`].clusterArn' --output text 2>/dev/null || echo "")
if [ -z "$CLUSTER_ARN" ]; then
  CLUSTER_ARN=$(aws ecs create-cluster --region "$REGION" \
    --cluster-name "$CLUSTER" \
    --capacity-providers FARGATE \
    --query 'cluster.clusterArn' --output text)
  echo "  ✓ created: ${CLUSTER_ARN}"
else
  echo "  ✓ exists: ${CLUSTER_ARN}"
fi

# ── 8. ALB + target group ─────────────────────────────────────────────────────
echo ""
echo "▶ 8/10  ALB + target group"
SUBNET_ID_1=$(echo "$SUBNET_IDS" | cut -d',' -f1)
SUBNET_ID_2=$(echo "$SUBNET_IDS" | cut -d',' -f2)

ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "${APP}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "not-found")
if [ "$ALB_ARN" = "not-found" ] || [ -z "$ALB_ARN" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer --region "$REGION" \
    --name "${APP}-alb" \
    --subnets "$SUBNET_ID_1" "$SUBNET_ID_2" \
    --security-groups "$ALB_SG_ID" \
    --scheme internet-facing \
    --type application \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  echo "  ✓ ALB created: ${ALB_ARN}"
else
  echo "  ✓ ALB exists: ${ALB_ARN}"
fi

TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" \
  --names "${APP}-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "not-found")
if [ "$TG_ARN" = "not-found" ] || [ -z "$TG_ARN" ]; then
  TG_ARN=$(aws elbv2 create-target-group --region "$REGION" \
    --name "${APP}-tg" \
    --protocol HTTP \
    --port "$CONTAINER_PORT" \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-path "/actuator/health" \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  echo "  ✓ target group created: ${TG_ARN}"
else
  echo "  ✓ target group exists: ${TG_ARN}"
fi

# HTTP listener
LISTENER_ARN=$(aws elbv2 describe-listeners --region "$REGION" \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn' --output text 2>/dev/null || echo "")
if [ -z "$LISTENER_ARN" ]; then
  aws elbv2 create-listener --region "$REGION" \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" > /dev/null
  echo "  ✓ HTTP listener created"
else
  echo "  ✓ HTTP listener exists"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)

# ── 9. ECS task definition ────────────────────────────────────────────────────
echo ""
echo "▶ 9/10  ECS task definition"
cat > /tmp/task-def-rendered.json <<EOF
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "executionRoleArn": "${EXEC_ROLE_ARN}",
  "taskRoleArn": "${TASK_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "${APP}",
      "image": "${ECR_URI}:latest",
      "essential": true,
      "portMappings": [
        { "containerPort": ${CONTAINER_PORT}, "hostPort": ${CONTAINER_PORT}, "protocol": "tcp" }
      ],
      "environment": [
        { "name": "AWS_REGION",                   "value": "${REGION}" },
        { "name": "SPRING_PROFILES_ACTIVE",        "value": "bedrock" },
        { "name": "BEDROCK_MODEL_ID",              "value": "us.amazon.nova-lite-v1:0" },
        { "name": "SPRING_AI_MODEL_EMBEDDING",     "value": "bedrock-titan" },
        { "name": "BEDROCK_EMBEDDING_MODEL_ID",    "value": "amazon.titan-embed-text-v2:0" },
        { "name": "LINKAGE_SEMANTIC_LLM_ENABLED",  "value": "true" }
      ],
      "secrets": [
        { "name": "DB_URL",      "valueFrom": "${SECRET_ARN}:DB_URL::" },
        { "name": "DB_USER",     "valueFrom": "${SECRET_ARN}:DB_USER::" },
        { "name": "DB_PASSWORD", "valueFrom": "${SECRET_ARN}:DB_PASSWORD::" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
EOF

aws ecs register-task-definition --region "$REGION" \
  --cli-input-json file:///tmp/task-def-rendered.json > /dev/null
echo "  ✓ task definition registered"

# Also update the repo copy with real ARNs
cp /tmp/task-def-rendered.json "$(dirname "$0")/ecs/task-definition.json"

# ── 10. ECS service ───────────────────────────────────────────────────────────
echo ""
echo "▶ 10/10  ECS service"
SERVICE_STATUS=$(aws ecs describe-services --region "$REGION" \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].status' --output text 2>/dev/null || echo "not-found")

if [ "$SERVICE_STATUS" = "ACTIVE" ]; then
  echo "  ✓ service already exists"
elif [ "$SERVICE_STATUS" = "INACTIVE" ]; then
  echo "  ⚠ service exists but is INACTIVE — recreating"
  aws ecs delete-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" --force > /dev/null
  SERVICE_STATUS="not-found"
fi

if [ "$SERVICE_STATUS" = "not-found" ] || [ "$SERVICE_STATUS" = "None" ]; then
  aws ecs create-service --region "$REGION" \
    --cluster "$CLUSTER" \
    --service-name "$SERVICE" \
    --task-definition "$TASK_FAMILY" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={
      subnets=[${SUBNET_ID_1},${SUBNET_ID_2}],
      securityGroups=[${ECS_SG_ID}],
      assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=${APP},containerPort=${CONTAINER_PORT}" \
    --health-check-grace-period-seconds 120 > /dev/null
  echo "  ✓ service created"
fi

# ── OIDC deploy role (GitHub Actions) ─────────────────────────────────────────
echo ""
echo "▶ OIDC deploy role for GitHub Actions"
OIDC_ROLE_NAME="${APP}-github-deploy-role"
OIDC_ROLE_ARN=$(aws iam get-role --role-name "$OIDC_ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || echo "not-found")

if [ "$OIDC_ROLE_ARN" = "not-found" ]; then
  GITHUB_REPO="sbecker11/linkage-engine"
  OIDC_PROVIDER="token.actions.githubusercontent.com"

  # Ensure OIDC provider exists
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_PROVIDER}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
    2>/dev/null || true

  OIDC_ROLE_ARN=$(aws iam create-role \
    --role-name "$OIDC_ROLE_NAME" \
    --assume-role-policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{
        \"Effect\":\"Allow\",
        \"Principal\":{\"Federated\":\"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}\"},
        \"Action\":\"sts:AssumeRoleWithWebIdentity\",
        \"Condition\":{
          \"StringLike\":{
            \"${OIDC_PROVIDER}:sub\":\"repo:${GITHUB_REPO}:*\"
          },
          \"StringEquals\":{
            \"${OIDC_PROVIDER}:aud\":\"sts.amazonaws.com\"
          }
        }
      }]
    }" \
    --query 'Role.Arn' --output text)

  aws iam put-role-policy --role-name "$OIDC_ROLE_NAME" \
    --policy-name DeployPolicy \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[
        {\"Effect\":\"Allow\",
         \"Action\":[\"ecr:GetAuthorizationToken\"],
         \"Resource\":\"*\"},
        {\"Effect\":\"Allow\",
         \"Action\":[\"ecr:BatchCheckLayerAvailability\",\"ecr:GetDownloadUrlForLayer\",
                     \"ecr:BatchGetImage\",\"ecr:PutImage\",\"ecr:InitiateLayerUpload\",
                     \"ecr:UploadLayerPart\",\"ecr:CompleteLayerUpload\"],
         \"Resource\":\"arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO}\"},
        {\"Effect\":\"Allow\",
         \"Action\":[\"ecs:RegisterTaskDefinition\",\"ecs:DescribeTaskDefinition\",
                     \"ecs:UpdateService\",\"ecs:DescribeServices\"],
         \"Resource\":\"*\"},
        {\"Effect\":\"Allow\",
         \"Action\":[\"iam:PassRole\"],
         \"Resource\":[\"${EXEC_ROLE_ARN}\",\"${TASK_ROLE_ARN}\"]}
      ]}"
  echo "  ✓ OIDC role created: ${OIDC_ROLE_ARN}"
else
  echo "  ✓ OIDC role exists: ${OIDC_ROLE_ARN}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Provisioning complete"
echo ""
echo "  ECR:        ${ECR_URI}"
echo "  Aurora:     ${DB_ENDPOINT}"
echo "  Secret ARN: ${SECRET_ARN}"
echo "  ALB:        http://${ALB_DNS}"
echo "  Cluster:    ${CLUSTER}"
echo "  Service:    ${SERVICE}"
echo ""
echo "  Next steps:"
echo "  1. Add this GitHub repository secret:"
echo "     AWS_DEPLOY_ROLE_ARN = ${OIDC_ROLE_ARN}"
echo ""
echo "  2. Run the deploy workflow:"
echo "     GitHub → Actions → deploy-ecr-ecs → Run workflow"
echo ""
echo "  3. After first deploy, seed the database:"
echo "     BASE_URL=http://${ALB_DNS} ./demo/seed-data.sh"
echo ""
echo "  4. Open the chord diagram:"
echo "     http://${ALB_DNS}/chord-diagram.html"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
