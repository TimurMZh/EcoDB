DO $$
BEGIN
    IF current_setting('server_version_num')::int < 140000 THEN
        RAISE EXCEPTION
            'PostgreSQL 14 or newer is required (found %)',
            current_setting('server_version');
    ELSIF current_setting('server_version_num')::int >= 150000 THEN
        RAISE WARNING
            'EcoDB is tested on PostgreSQL 14 (found %). Install 14 if you can.',
            current_setting('server_version');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_available_extensions WHERE name = 'postgis'
    ) THEN
        RAISE EXCEPTION
            'PostGIS is not installed for this PostgreSQL. Install PostGIS 3.4 and run init-db again.';
    END IF;
END
$$;
