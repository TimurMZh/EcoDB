# EcoDB

Relational database for environmental monitoring (air, surface water, groundwater, soil, vegetation). Built on PostgreSQL 14 with PostGIS, intended for use with ArcGIS Enterprise Query Layers.

Spatial data uses **WGS84 / EPSG:4326**. The application schema is `eco`.

## Requirements

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- PostgreSQL client tools (`psql`, `pg_isready`) on the host — needed to run migrations

On macOS:

```bash
brew install libpq
# then add libpq to PATH, e.g. echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc
```

## Quick start

```bash
git clone https://github.com/TimurMZh/EcoDB.git
cd EcoDB

docker compose up -d
chmod +x sql/apply.sh
./sql/apply.sh
```

Default connection:

| | |
|---|---|
| Host | `localhost` |
| Port | `5432` |
| Database | `eco_monitoring` |
| User / password | `eco` / `eco` |

Override with `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD` if needed.

Adminer (web SQL UI) is at [http://localhost:8080](http://localhost:8080). Server: `postgis`, credentials as above.

## Migrations

Numbered SQL files in `sql/migrations/` are applied in order. Already-applied versions are skipped (`eco.schema_migrations`).

| File | Contents |
|---|---|
| `001_init.sql` | PostGIS extension, schema `eco`, migration log |
| `002_tables.sql` | Tables, constraints, media-type and QC reference data |
| `003_indexes.sql` | GIST on geometry, btree indexes, unique keys |
| `004_functions.sql` | Triggers, lab-value parsing, exceedance checks, staging ETL |
| `005_views.sql` | ArcGIS Query Layer views and `SELECT` grants |

Rebuild the schema from scratch:

```bash
./sql/apply.sh --reset
```

## Schema overview

```
sites ── monitoring_points (Point, 4326)
              │
              ├── sampling_events ── samples ── results ── result_exceedances
              ├── field_measurements
              └── water_levels

parameters ── guideline_values ── guideline_standards
laboratories
staging_lab_import   →   fn_process_staging_import()
```

**Media types:** `air`, `surface_water`, `groundwater`, `soil`, `vegetation`.

**QA/QC codes:** `A` / `B` / `C` (included in latest results), `D` / `R` (rejected / review — excluded from `vw_latest_results`).

Reference catalogs (sites, labs, parameters, PDK limits) are empty after install. Load them before importing lab files.

## Lab import

1. Load sites, monitoring points, laboratories, parameters, aliases, and guideline values.
2. Insert raw spreadsheet rows into `eco.staging_lab_import` (no foreign keys; keep the original cell text).
3. Process a batch:

```sql
SELECT * FROM eco.fn_process_staging_import('AIR_PILOT');
```

The function maps point and parameter aliases, parses values such as `<0.01`, upserts events / samples / results, and records failures on the staging row (`process_error`). Exceedances against PDK (and other standards) are calculated by trigger.

To recompute all exceedances after changing guideline values:

```sql
SELECT eco.fn_recalc_all_exceedances();
```

## Views (ArcGIS Query Layers)

Each view has a unique integer `objectid` and optional `geom` (`Point`, 4326). Null geometry is allowed.

| View | One row per | `objectid` |
|---|---|---|
| `eco.vw_results_flat` | lab result | `result_id` |
| `eco.vw_exceedances_summary` | result × standard | `exceedance_id` |
| `eco.vw_latest_results` | latest result per (point, parameter) | `result_id` |
| `eco.vw_water_levels` | groundwater level | `level_id` |

Register these as Query Layers in ArcGIS Enterprise against the `eco` schema.

## Smoke test

Applies sample inserts, import, and exceedance checks, then **rolls back**:

```bash
psql -h localhost -U eco -d eco_monitoring -v ON_ERROR_STOP=1 -f sql/verify_phase1.sql
```

Password: `eco`. Requires the schema to be applied first.

## Project layout

```
docker-compose.yml      PostGIS 14-3.4 + Adminer
sql/apply.sh            Apply (or reset) migrations
sql/verify_phase1.sql   Phase 1 smoke test (always ROLLBACK)
sql/migrations/         Numbered schema scripts
```

`.env` is gitignored. Compose uses the defaults above unless you change them.
