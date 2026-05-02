#!/usr/bin/env bash
# scripts/start.sh — run linkage-engine locally with Spring profile "local".
#
# Prerequisites:
#   - PostgreSQL + pgvector reachable at DB_URL (see README)
#   - .env in the repo root (copy from .env.example)
#
# Usage:
#   ./scripts/start.sh              # fails fast if DB is not reachable
#   ./scripts/start.sh --with-db   # start or create Docker pgvector-db, then run the app
#
# When the HTTP port accepts connections, your default browser opens (macOS: open,
# Linux: xdg-open). Override the port with SERVER_PORT in .env (Spring Boot). Override the
# path with START_OPEN_PATH (default /chord-diagram.html — "/" has no handler and 404s).
#
# From anywhere:
#   /path/to/linkage-engine/scripts/start.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WITH_DB=false
for arg in "$@"; do
  case "$arg" in
    --with-db) WITH_DB=true ;;
    -h | --help)
      grep '^# ' "$0" | sed 's/^# \{0,1\}//' | head -20
      exit 0
      ;;
    *)
      echo "error: unknown option: $arg (try --with-db or --help)" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f .env ]]; then
  echo "error: missing .env in ${ROOT}" >&2
  echo "  cp .env.example .env   # then edit if needed" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "${ROOT}/.env"
set +a

# Parse host/port from jdbc:postgresql://host:port/db (defaults match .env.example)
DB_HOST="localhost"
DB_PORT="5434"
if [[ "${DB_URL:-}" =~ jdbc:postgresql://([^:/]+):([0-9]+)/ ]]; then
  DB_HOST="${BASH_REMATCH[1]}"
  DB_PORT="${BASH_REMATCH[2]}"
elif [[ "${DB_URL:-}" =~ jdbc:postgresql://([^:/]+)/ ]]; then
  DB_HOST="${BASH_REMATCH[1]}"
  DB_PORT="5432"
fi

tcp_open() {
  local host="$1" port="$2"
  [[ "$host" == "localhost" ]] && host="127.0.0.1"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 2 "$host" "$port"
  else
    (echo >/dev/tcp/${host}/${port}) >/dev/null 2>&1
  fi
}

start_pgvector_container() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "error: --with-db requires Docker in PATH" >&2
    exit 1
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'pgvector-db'; then
    echo "Starting existing container pgvector-db …"
    docker start pgvector-db >/dev/null
  else
    echo "Creating container pgvector-db (first time; host port ${DB_PORT} from DB_URL) …"
    docker run -d \
      --name pgvector-db \
      -e POSTGRES_USER=ancestry \
      -e POSTGRES_PASSWORD=password \
      -e POSTGRES_DB=linkage_db \
      -p "${DB_PORT}:5432" \
      ankane/pgvector
  fi
  echo "Waiting for TCP ${DB_HOST}:${DB_PORT} …"
  local i
  for i in $(seq 1 45); do
    if tcp_open "$DB_HOST" "$DB_PORT"; then
      echo "PostgreSQL is accepting connections."
      return 0
    fi
    sleep 1
  done
  echo "error: PostgreSQL did not become ready on ${DB_HOST}:${DB_PORT} within 45s" >&2
  exit 1
}

if [[ "$WITH_DB" == true ]]; then
  start_pgvector_container
fi

if ! tcp_open "$DB_HOST" "$DB_PORT"; then
  echo "error: cannot reach PostgreSQL at ${DB_HOST}:${DB_PORT} (from DB_URL in .env)" >&2
  echo "  Start it manually (see README), or run:" >&2
  echo "    ./scripts/start.sh --with-db" >&2
  exit 1
fi

if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'pgvector-db'; then
    echo "Using running container: pgvector-db"
  fi
fi

APP_PORT="${SERVER_PORT:-8080}"
# Root "/" has no mapping; main static UI lives here (see src/main/resources/static/).
START_OPEN_PATH="${START_OPEN_PATH:-/chord-diagram.html}"

open_http_url() {
  local url="$1"
  case "$(uname -s)" in
    Darwin) open "$url" ;;
    Linux)
      if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 || true
      elif command -v sensible-browser >/dev/null 2>&1; then
        sensible-browser "$url" >/dev/null 2>&1 || true
      else
        echo "Open in a browser: ${url}" >&2
      fi
      ;;
    *) echo "Open in a browser: ${url}" >&2 ;;
  esac
}

# After Tomcat binds, open the chord UI (non-blocking for the main process).
(
  for i in $(seq 1 120); do
    if tcp_open 127.0.0.1 "$APP_PORT"; then
      open_http_url "http://127.0.0.1:${APP_PORT}${START_OPEN_PATH}"
      exit 0
    fi
    sleep 1
  done
) &

echo "Starting linkage-engine (profile=local) from ${ROOT} …"
echo "Browser will open when http://127.0.0.1:${APP_PORT}${START_OPEN_PATH} is ready."
./mvnw spring-boot:run -Dspring-boot.run.profiles=local
