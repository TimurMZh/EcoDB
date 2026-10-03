-- Проверка ролей доступа (миграция 011). Ничего не меняет.
-- psql -v ON_ERROR_STOP=1 -f sql/verify_roles.sql

DO $$
DECLARE
    v_role text;
    v_obj  text;
    n      bigint;
    admin_only text[] := ARRAY[
        'eco.ref_media_types', 'eco.ref_qc_codes', 'eco.guideline_standards',
        'eco.guideline_values', 'eco.qa_rules', 'eco.schema_migrations'
    ];
    gis_views text[] := ARRAY[
        'eco.vw_results_flat', 'eco.vw_exceedances_summary',
        'eco.vw_latest_results', 'eco.vw_water_levels'
    ];
BEGIN
    -- Групповые роли существуют, без логина и без суперпользователя.
    FOREACH v_role IN ARRAY ARRAY['eco_read', 'eco_edit', 'eco_admin'] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_roles
            WHERE rolname = v_role AND NOT rolcanlogin AND NOT rolsuper
        ) THEN
            RAISE EXCEPTION 'role % is missing, can log in, or is superuser', v_role;
        END IF;
    END LOOP;

    -- PUBLIC не имеет прав на базу, схему, таблицы и функции eco.
    IF EXISTS (
        SELECT 1 FROM pg_database d, aclexplode(d.datacl) a
        WHERE d.datname = current_database() AND a.grantee = 0
    ) THEN
        RAISE EXCEPTION 'PUBLIC has privileges on database %', current_database();
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_namespace s, aclexplode(s.nspacl) a
        WHERE s.nspname = 'eco' AND a.grantee = 0
    ) THEN
        RAISE EXCEPTION 'PUBLIC has privileges on schema eco';
    END IF;

    SELECT count(*) INTO n
    FROM pg_class c
    JOIN pg_namespace s ON s.oid = c.relnamespace,
         aclexplode(c.relacl) a
    WHERE s.nspname = 'eco' AND a.grantee = 0;
    IF n > 0 THEN
        RAISE EXCEPTION 'PUBLIC has % privileges on eco tables/views', n;
    END IF;

    SELECT count(*) INTO n
    FROM pg_proc p
    JOIN pg_namespace s ON s.oid = p.pronamespace
    WHERE s.nspname = 'eco'
      AND (p.proacl IS NULL
           OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0));
    IF n > 0 THEN
        RAISE EXCEPTION 'PUBLIC can execute % eco functions', n;
    END IF;

    SELECT count(*) INTO n
    FROM pg_default_acl d, aclexplode(d.defaclacl) a
    WHERE a.grantee = 0
      AND d.defaclnamespace = 'eco'::regnamespace;
    IF n > 0 THEN
        RAISE EXCEPTION 'default privileges still grant to PUBLIC (% entries)', n;
    END IF;

    -- eco_admin владеет схемой и всеми объектами.
    IF (SELECT nspowner FROM pg_namespace WHERE nspname = 'eco') <> 'eco_admin'::regrole THEN
        RAISE EXCEPTION 'schema eco is not owned by eco_admin';
    END IF;

    SELECT count(*) INTO n
    FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
    WHERE s.nspname = 'eco' AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
      AND c.relowner <> 'eco_admin'::regrole;
    IF n > 0 THEN
        RAISE EXCEPTION '% eco relations are not owned by eco_admin', n;
    END IF;

    SELECT count(*) INTO n
    FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
    WHERE s.nspname = 'eco' AND p.proowner <> 'eco_admin'::regrole;
    IF n > 0 THEN
        RAISE EXCEPTION '% eco functions are not owned by eco_admin', n;
    END IF;

    -- eco_read: SELECT везде, запись нигде.
    FOR v_obj IN
        SELECT format('%s.%s', s.nspname, c.relname)
        FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
        WHERE s.nspname = 'eco' AND c.relkind IN ('r', 'p', 'v', 'm')
    LOOP
        IF NOT has_table_privilege('eco_read', v_obj, 'SELECT') THEN
            RAISE EXCEPTION 'eco_read cannot SELECT %', v_obj;
        END IF;
        IF has_table_privilege('eco_read', v_obj, 'INSERT,UPDATE,DELETE,TRUNCATE') THEN
            RAISE EXCEPTION 'eco_read can write to %', v_obj;
        END IF;
    END LOOP;

    -- eco_edit: пишет в данные, но не в нормативы и не в DDL.
    FOREACH v_obj IN ARRAY ARRAY[
        'eco.staging_lab_import', 'eco.results', 'eco.samples',
        'eco.sampling_events', 'eco.result_exceedances', 'eco.monitoring_points',
        'eco.point_aliases', 'eco.parameter_aliases', 'eco.qa_runs'
    ] LOOP
        IF NOT has_table_privilege('eco_edit', v_obj, 'INSERT,UPDATE,DELETE') THEN
            RAISE EXCEPTION 'eco_edit cannot write to %', v_obj;
        END IF;
    END LOOP;

    FOREACH v_obj IN ARRAY admin_only LOOP
        IF has_table_privilege('eco_edit', v_obj, 'INSERT,UPDATE,DELETE,TRUNCATE') THEN
            RAISE EXCEPTION 'eco_edit can write to admin-only table %', v_obj;
        END IF;
    END LOOP;

    IF has_schema_privilege('eco_edit', 'eco', 'CREATE') THEN
        RAISE EXCEPTION 'eco_edit can CREATE in schema eco';
    END IF;

    IF NOT has_function_privilege('eco_edit', 'eco.fn_process_staging_import(text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'eco_edit cannot execute fn_process_staging_import';
    END IF;

    -- eco_gis: только четыре представления, не член групп.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eco_gis' AND rolcanlogin AND NOT rolsuper) THEN
        RAISE EXCEPTION 'eco_gis is missing, cannot log in, or is superuser';
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_auth_members m
        WHERE m.member = 'eco_gis'::regrole
    ) THEN
        RAISE EXCEPTION 'eco_gis must not be a member of any group role';
    END IF;

    FOR v_obj IN
        SELECT format('%s.%s', s.nspname, c.relname)
        FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
        WHERE s.nspname = 'eco' AND c.relkind IN ('r', 'p', 'v', 'm')
    LOOP
        IF v_obj = ANY (gis_views) THEN
            IF NOT has_table_privilege('eco_gis', v_obj, 'SELECT') THEN
                RAISE EXCEPTION 'eco_gis cannot SELECT %', v_obj;
            END IF;
        ELSIF has_table_privilege('eco_gis', v_obj, 'SELECT') THEN
            RAISE EXCEPTION 'eco_gis can SELECT % (only the 4 views are allowed)', v_obj;
        END IF;
        IF has_table_privilege('eco_gis', v_obj, 'INSERT,UPDATE,DELETE,TRUNCATE') THEN
            RAISE EXCEPTION 'eco_gis can write to %', v_obj;
        END IF;
    END LOOP;

    RAISE NOTICE 'Roles OK';
END
$$;

-- Справка: логины и их группы. Суперпользователей должно быть не больше одного (postgres / bootstrap).
SELECT r.rolname AS login,
       r.rolsuper AS superuser,
       coalesce(string_agg(g.rolname, ', ' ORDER BY g.rolname), '') AS member_of,
       r.rolvaliduntil AS valid_until
FROM pg_roles r
LEFT JOIN pg_auth_members m ON m.member = r.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE r.rolcanlogin AND r.rolname NOT LIKE 'pg\_%'
GROUP BY r.rolname, r.rolsuper, r.rolvaliduntil
ORDER BY r.rolname;
