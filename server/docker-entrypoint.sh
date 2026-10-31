#!/bin/sh
# docker-entrypoint.sh server|worker
#   server (default; "web" still works): apply schema migrations and the seed data, then serve
#                                        the API and the sign-in pages.
#   worker:                              the background worker (waits until the server has migrated).
# Any failure exits non-zero so the container refuses to start (no half-migrated DB served).
set -e
cd /app

TSX=./node_modules/.bin/tsx
: "${DATABASE_FILE:=/app/data/ohana.db}"
export DATABASE_FILE

case "${1:-server}" in
  server|web)
    echo "[entrypoint] applying schema migrations to ${DATABASE_FILE}"
    "$TSX" scripts/db-migrate.ts
    echo "[entrypoint] loading seed data (units, ingredients)"
    "$TSX" scripts/seed.ts
    echo "[entrypoint] starting server on port ${PORT:-8000}"
    exec "$TSX" http/index.ts
    ;;
  worker)
    echo "[entrypoint] starting worker"
    exec "$TSX" worker/index.ts
    ;;
  setup-link)
    shift
    exec "$TSX" scripts/setup-link.ts "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
