#!/usr/bin/env bash
# scripts/start.sh — run linkage-engine locally with Spring profile "local".
#
# Prerequisites:
#   - PostgreSQL + pgvector reachable at DB_URL (see README: Docker pgvector-db)
#   - .env in the repo root (copy from .env.example)
#
# Usage (from anywhere):
#   ./scripts/start.sh
#   /path/to/linkage-engine/scripts/start.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "error: missing .env in ${ROOT}" >&2
  echo "  cp .env.example .env   # then edit if needed" >&2
  exit 1
fi

if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'pgvector-db'; then
    echo "Found running container: pgvector-db"
  else
    echo "Note: no Docker container named pgvector-db — ensure PostgreSQL is up for DB_URL (see README)." >&2
  fi
fi

set -a
# shellcheck source=/dev/null
source "${ROOT}/.env"
set +a

echo "Starting linkage-engine (profile=local) from ${ROOT} …"
exec ./mvnw spring-boot:run -Dspring-boot.run.profiles=local
