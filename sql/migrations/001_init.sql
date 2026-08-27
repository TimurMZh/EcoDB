-- 001_init.sql
-- PostgreSQL 14+ / PostGIS, UTF-8. Schema eco for ArcGIS Query Layers.

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS eco;
COMMENT ON SCHEMA eco IS
  'Реляционная БД экологического мониторинга (воздух, воды, почва, растительность). '
  'Пространственная СК: WGS84 / EPSG:4326.';

CREATE TABLE IF NOT EXISTS eco.schema_migrations (
    version     text        PRIMARY KEY,
    description text        NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE eco.schema_migrations IS 'Журнал применённых SQL-миграций схемы.';

INSERT INTO eco.schema_migrations (version, description)
VALUES ('001', 'Расширение PostGIS, схема eco, журнал миграций')
ON CONFLICT (version) DO NOTHING;
