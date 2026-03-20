# ECS task definition

## Secrets Manager (`secrets` block)

Runtime database credentials are loaded from **one JSON secret** in AWS Secrets Manager (standard for this project).

1. Create the secret (see `deploy/secrets/runtime-secret.json.example` and `docs/SECRETS_MANAGER.md`):

   ```bash
   aws secretsmanager create-secret \
     --name linkage-engine/runtime \
     --secret-string file://deploy/secrets/runtime-secret.json \
     --region us-west-1
   ```

2. Get the **full** secret ARN (includes a hyphen + random suffix):

   ```bash
   aws secretsmanager describe-secret --secret-id linkage-engine/runtime --region us-west-1 --query ARN --output text
   ```

3. Edit `task-definition.json` `secrets[].valueFrom` values. The committed file uses example suffix **`a1b2c3`** — replace it with the **6-character suffix** from your secret’s ARN (output of `describe-secret`, e.g. `...secret:linkage-engine/runtime-XyZ9Ab` → use `XyZ9Ab`). Also fix **account ID** and **region** if they differ.

   Each `valueFrom` must be: `FULL_SECRET_ARN` + `:` + `JSON_KEY` + `::`  
   Example: `arn:aws:secretsmanager:us-west-1:123456789012:secret:linkage-engine/runtime-XyZ9Ab:DB_URL::`

4. Ensure the ECS **task execution role** can call `secretsmanager:GetSecretValue` on that secret (see `deploy/iam/ecs-execution-role-secrets-statement.json`).

If you prefer **three separate string secrets** (no JSON keys), see `docs/SECRETS_MANAGER.md` — each `valueFrom` is then the **full secret ARN only** (no `:DB_URL::` suffix).
