# Secret material (do not commit real files)

- Use **`runtime-secret.json.example`** as a template only.
- Copy to a local file (e.g. `runtime-secret.json`), fill real values, and run `aws secretsmanager create-secret` — see `docs/SECRETS_MANAGER.md`.
- **Never** commit `runtime-secret.json` or any file containing real passwords.
