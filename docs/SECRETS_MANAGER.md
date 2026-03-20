# AWS Secrets Manager (standard for runtime secrets)

All **sensitive runtime configuration** for linkage-engine in AWS should live in **AWS Secrets Manager**, not in GitHub, not in the ECS task definition `environment` block, and not baked into the container image.

## What goes where

| Secret material | Where it lives | How the app receives it |
| :--- | :--- | :--- |
| `DB_URL`, `DB_USER`, `DB_PASSWORD` | **Secrets Manager** | ECS `secrets` → container **environment variables** (Spring reads `DB_*` as today) |
| Bedrock / AWS calls | **Not** in Secrets Manager | **IAM task role** on the ECS task (default credential chain) |
| Optional third-party API keys (e.g. future providers) | **Secrets Manager** | ECS `secrets` → env vars |
| GitHub Actions OIDC deploy role | **Not** in Secrets Manager* | GitHub **encrypted secret** or **repository variable**, or a **fixed ARN** in the workflow file; IAM **trust policy** enforces who can assume the role |

\*You cannot call `GetSecretValue` before you have AWS credentials. The OIDC “bootstrap” role must be chosen from GitHub (or hardcoded). That ARN is not equivalent to a database password—access is still gated by `sts:AssumeRoleWithWebIdentity`.

## Recommended: one JSON secret per environment

Create one secret per environment (example name: `linkage-engine/prod/runtime`).

**Secret value (JSON):**

```json
{
  "DB_URL": "jdbc:postgresql://your-rds.region.rds.amazonaws.com:5432/linkage_db",
  "DB_USER": "app_user",
  "DB_PASSWORD": "use-a-long-random-password"
}
```

**Create (CLI):**

```bash
aws secretsmanager create-secret \
  --name linkage-engine/prod/runtime \
  --description "Linkage engine runtime config" \
  --secret-string file://runtime-secret.json \
  --region us-west-1
```

**Resolve the full secret ARN** (includes AWS-assigned suffix; required for exact ARNs in some setups):

```bash
aws secretsmanager describe-secret \
  --secret-id linkage-engine/prod/runtime \
  --region us-west-1 \
  --query ARN --output text
```

**ECS / Fargate `valueFrom` format** for a key inside a JSON secret:

```text
arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:SECRET_NAME_AND_SUFFIX:JSON_KEY::
```

Example (replace with your real ARN prefix from `describe-secret`; the segment after `secret:` includes the random suffix):

```text
arn:aws:secretsmanager:us-west-1:123456789012:secret:linkage-engine/prod/runtime-a1b2c3:DB_URL::
```

Use the same pattern for `DB_USER` and `DB_PASSWORD` with `:DB_USER::` and `:DB_PASSWORD::` at the end.

See `deploy/ecs/task-definition.json` for a working template wired to three JSON keys on one secret.

## Alternative: separate string secrets

You can instead store three secrets (plain string, not JSON)—one per value. That matches older templates and is easier to paste into the console, at the cost of more secret resources to rotate.

## IAM: ECS task execution role

The **execution role** must allow ECS to pull secrets into the task **before** the app starts:

- `secretsmanager:GetSecretValue` on the secret ARN(s) (or `resource:*` with a tight `Condition` on secret name prefix)
- `kms:Decrypt` if the secret uses a customer-managed KMS key

See `deploy/iam/ecs-execution-role-secrets-statement.json`.

## IAM: ECS task role (application)

The **task role** is for the running app (Bedrock, S3, etc.). It does **not** need Secrets Manager access if all sensitive values are injected as env vars by the execution role (standard Fargate pattern).

## Local development

Local runs typically use `.env` or shell exports for `DB_*` (see `README.md`). **Do not** commit secrets. Optionally use AWS CLI + `source` from `aws secretsmanager get-secret-value` if you want parity with prod.

## Rotation

Prefer **Secrets Manager rotation** (RDS integration) for database passwords, or rotate manually and update the secret; redeploy ECS tasks so new tasks pick up new values (or use dynamic reference behavior documented by AWS for your setup).

## References

- `deploy/ecs/task-definition.json`
- `docs/DEPLOYMENT_ECS_FARGATE.md`
