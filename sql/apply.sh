#!/usr/bin/env bash
# Apply numbered SQL migrations. Already-applied versions are skipped.
# Recreate from scratch: ./sql/apply.sh --reset
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-eco}"
PGDATABASE="${PGDATABASE:-eco_monitoring}"
export PGPASSWORD="${PGPASSWORD:-eco}"
export PGHOST PGPORT PGUSER PGDATABASE

RESET=0
if [[ "${1:-}" == "--reset" ]]; then
  RESET=1
fi

echo "Waiting for PostgreSQL at ${PGHOST}:${PGPORT} ..."
for i in $(seq 1 60); do
  if pg_isready -q; then
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "PostgreSQL is not ready after 60s" >&2
    exit 1
  fi
  sleep 1
done

if [[ "$RESET" -eq 1 ]]; then
  echo "Dropping schema eco (reset) ..."
  psql -v ON_ERROR_STOP=1 -c "DROP SCHEMA IF EXISTS eco CASCADE;"
fi

echo "Applying migrations to ${PGDATABASE} ..."
for f in "${ROOT}"/sql/migrations/*.sql; do
  base="$(basename "$f")"
  ver="${base%%_*}"

  applied="$(psql -tAc "
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.tables
      WHERE table_schema = 'eco' AND table_name = 'schema_migrations'
    ) AND EXISTS (
      SELECT 1 FROM eco.schema_migrations WHERE version = '${ver}'
    );
  " | tr -d '[:space:]')"

  if [[ "$applied" == "t" ]]; then
    echo "  skip ${base} (already applied)"
    continue
  fi

  echo "  -> ${base}"
  psql -v ON_ERROR_STOP=1 -f "$f"
done

echo
echo "Schema objects in eco:"
psql -v ON_ERROR_STOP=1 -c "
SELECT
  CASE c.relkind
    WHEN 'r' THEN 'table'
    WHEN 'v' THEN 'view'
    ELSE c.relkind::text
  END AS kind,
  c.relname AS name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'eco'
  AND c.relkind IN ('r', 'v')
  AND c.relname NOT LIKE 'pg_%'
ORDER BY kind, name;
"

echo
echo "Applied migrations:"
psql -v ON_ERROR_STOP=1 -c "SELECT version, description, applied_at FROM eco.schema_migrations ORDER BY version;"

echo "Done."
