#!/bin/sh
# docker-entrypoint.sh web|worker
#   web (default): apply schema migrations and the seed data, then serve Next.js.
#   worker:        the background worker (waits until the web process has migrated).
# Any failure exits non-zero so the container refuses to start (no half-migrated DB served).
set -e
cd /app

TSX=./node_modules/.bin/tsx
: "${DATABASE_FILE:=/app/data/ohana.db}"
export DATABASE_FILE

case "${1:-web}" in
  web)
    echo "[entrypoint] applying schema migrations to ${DATABASE_FILE}"
    "$TSX" scripts/db-migrate.ts
    echo "[entrypoint] loading seed data (units, ingredients)"
    "$TSX" scripts/seed.ts
    echo "[entrypoint] starting server on port ${PORT:-8000}"
    exec node server.js
    ;;
  worker)
    echo "[entrypoint] starting worker"
    exec "$TSX" worker/index.ts
    ;;
  *)
    exec "$@"
    ;;
esac
