resource "aws_secretsmanager_secret" "runtime" {
  name        = "${var.app}/runtime"
  description = "${var.app} runtime credentials"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "runtime" {
  secret_id = aws_secretsmanager_secret.runtime.id

  secret_string = jsonencode({
    DB_URL         = var.db_url
    DB_USER        = var.db_username
    DB_PASSWORD    = var.db_password
    INGEST_API_KEY = var.ingest_api_key
  })
}
