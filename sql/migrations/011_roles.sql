-- 011_roles.sql
-- Групповые роли доступа: eco_read, eco_edit, eco_admin (все NOLOGIN).
-- Логины с паролями создаются вручную на сервере, см. docs/roles.md.
-- Первый запуск — от суперпользователя (создание ролей, смена владельца БД).
-- Повторные запуски (apply.sh --reset) идут под ролью eco_admin и ничего не ломают.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eco_read') THEN
        CREATE ROLE eco_read NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eco_edit') THEN
        CREATE ROLE eco_edit NOLOGIN IN ROLE eco_read;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eco_admin') THEN
        CREATE ROLE eco_admin NOLOGIN IN ROLE eco_edit;
    END IF;
END
$$;

-- Комментарии к ролям и настройки ролей требуют CREATEROLE; под eco_admin пропускаются.
DO $$
BEGIN
    IF (SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = current_user) THEN
        COMMENT ON ROLE eco_read  IS 'Чтение всех таблиц и представлений схемы eco.';
        COMMENT ON ROLE eco_edit  IS 'Загрузка данных (ETL): запись в данные, справочники точек/показателей, staging и QA. Без DDL и без нормативов.';
        COMMENT ON ROLE eco_admin IS 'Владелец БД и схемы eco: миграции, нормативы, правила QA.';
        ALTER ROLE eco_gis SET statement_timeout = '60s';
    END IF;
END
$$;

-- Владелец базы, схемы и всех объектов — eco_admin.
DO $$
DECLARE
    r record;
BEGIN
    EXECUTE format('ALTER DATABASE %I OWNER TO eco_admin', current_database());
    ALTER SCHEMA eco OWNER TO eco_admin;

    FOR r IN
        SELECT c.oid::regclass AS obj, c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'eco'
          AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d
              WHERE d.classid = 'pg_class'::regclass
                AND d.objid = c.oid
                AND d.deptype IN ('a', 'i')
          )
    LOOP
        IF r.relkind = 'S' THEN
            EXECUTE format('ALTER SEQUENCE %s OWNER TO eco_admin', r.obj);
        ELSE
            EXECUTE format('ALTER TABLE %s OWNER TO eco_admin', r.obj);
        END IF;
    END LOOP;

    FOR r IN
        SELECT p.oid::regprocedure AS fn
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'eco'
    LOOP
        EXECUTE format('ALTER ROUTINE %s OWNER TO eco_admin', r.fn);
    END LOOP;
END
$$;

-- Убрать широкие права из 005 (PUBLIC) и 010 (eco_gis на все таблицы).
DO $$
BEGIN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO eco_read, eco_gis', current_database());
END
$$;
REVOKE ALL ON SCHEMA eco FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA eco FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA eco FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA eco FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

DO $$
DECLARE
    v_role text;
BEGIN
    FOREACH v_role IN ARRAY ARRAY[current_user::text, 'eco_admin'] LOOP
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA eco REVOKE ALL ON TABLES FROM PUBLIC', v_role);
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA eco REVOKE ALL ON TABLES FROM eco_gis', v_role);
    END LOOP;
    -- EXECUTE для PUBLIC выдаётся глобальным default ACL, не схемным.
    ALTER DEFAULT PRIVILEGES FOR ROLE eco_admin REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
END
$$;

-- eco_read
GRANT USAGE ON SCHEMA eco TO eco_read;
GRANT SELECT ON ALL TABLES IN SCHEMA eco TO eco_read;
ALTER DEFAULT PRIVILEGES FOR ROLE eco_admin IN SCHEMA eco
    GRANT SELECT ON TABLES TO eco_read;

-- eco_edit: запись везде, кроме нормативов, кодов, правил QA и журнала миграций.
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA eco TO eco_edit;
REVOKE INSERT, UPDATE, DELETE ON
    eco.ref_media_types,
    eco.ref_qc_codes,
    eco.guideline_standards,
    eco.guideline_values,
    eco.qa_rules,
    eco.schema_migrations
FROM eco_edit;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA eco TO eco_edit;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA eco TO eco_edit;
ALTER DEFAULT PRIVILEGES FOR ROLE eco_admin IN SCHEMA eco
    GRANT INSERT, UPDATE, DELETE ON TABLES TO eco_edit;
ALTER DEFAULT PRIVILEGES FOR ROLE eco_admin IN SCHEMA eco
    GRANT USAGE, SELECT ON SEQUENCES TO eco_edit;
ALTER DEFAULT PRIVILEGES FOR ROLE eco_admin IN SCHEMA eco
    GRANT EXECUTE ON FUNCTIONS TO eco_edit;

-- eco_gis (логин из 010): только четыре представления Query Layer.
REVOKE SELECT ON ALL TABLES IN SCHEMA eco FROM eco_gis;
GRANT USAGE ON SCHEMA eco TO eco_gis;
GRANT SELECT ON
    eco.vw_results_flat,
    eco.vw_exceedances_summary,
    eco.vw_latest_results,
    eco.vw_water_levels
TO eco_gis;

INSERT INTO eco.schema_migrations (version, description)
VALUES ('011', 'Роли eco_read / eco_edit / eco_admin, eco_gis только на представления, без прав PUBLIC')
ON CONFLICT (version) DO NOTHING;
