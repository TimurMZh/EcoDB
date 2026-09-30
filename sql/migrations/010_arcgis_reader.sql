-- 010_arcgis_reader.sql
-- Учётная запись только на чтение для регистрации Query Layer в ArcGIS Enterprise.
-- Пароль dev-стенда. Перед промышленной средой заменить.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eco_gis') THEN
        CREATE ROLE eco_gis LOGIN PASSWORD 'eco_gis';
    END IF;
END
$$;

GRANT USAGE ON SCHEMA eco TO eco_gis;
GRANT SELECT ON ALL TABLES IN SCHEMA eco TO eco_gis;
ALTER DEFAULT PRIVILEGES IN SCHEMA eco GRANT SELECT ON TABLES TO eco_gis;

COMMENT ON ROLE eco_gis IS
  'Чтение схемы eco для ArcGIS Enterprise Query Layer. Без INSERT/UPDATE/DELETE.';

INSERT INTO eco.schema_migrations (version, description)
VALUES ('010', 'Роль eco_gis: SELECT на схему eco для ArcGIS')
ON CONFLICT (version) DO NOTHING;
