# Server requirements (EcoDB)

Short sizing guide for hosting EcoDB: PostgreSQL 14 + PostGIS (Docker), Python ETL, ArcGIS Enterprise Query Layers.

## Software

| Component | Requirement |
| --------- | ----------- |
| OS | Windows Server (or Linux) |
| Runtime | Docker + Docker Compose |
| Database image | `postgis/postgis:14-3.4` |
| PostgreSQL client | `psql`, `pg_isready` (migrations via `sql/apply.sh`) |
| Python | 3.11+ |
| ETL deps | `etl/requirements.txt` (`openpyxl`, `psycopg2-binary`, `pymupdf`) |
| GIS client | ArcGIS Enterprise — Query Layers on schema `eco` (EPSG:4326) |

Optional: Adminer (`adminer:4`) for web SQL UI. Prefer internal-only access in production.

## Hardware

Current data volume is small (lab Excel/PDF imports + ~50 MB Oskemen station files). For a dedicated DB/ETL host:

| Resource | Minimum | Recommended |
| -------- | ------- | ----------- |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Disk | 40 GB | 100 GB SSD |
| Network | LAN to ArcGIS / admins | Stable; see ports below |

If ArcGIS Enterprise runs on the same machine, add its own RAM/CPU on top (often 16 GB+). Prefer a separate host for EcoDB when ArcGIS is already heavy.

## Ports

| Port | Service | Notes |
| ---- | ------- | ----- |
| 5432 | PostgreSQL / PostGIS | Required for ArcGIS and ETL |
| 8080 | Adminer | Optional; restrict or disable in production |

Outbound HTTPS is needed only if running `dataset/fetch_oskemen_raw.py` (AirData.kz, Open-Meteo).

## Default connection (dev)

| | |
| --- | --- |
| Database | `eco_monitoring` |
| User / password | `eco` / `eco` |

Change credentials before any production deploy.

## Roles on the server

1. `docker compose up -d` — PostGIS (+ Adminer)
2. Apply schema — `sql/apply.sh` (or Windows equivalent)
3. Run ETL — `python etl/phase2.py` … `phase4.py` as needed
4. Register ArcGIS Query Layers on views such as `eco.vw_results_flat`, `eco.vw_latest_results`
