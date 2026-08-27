-- 004_functions.sql
-- Триггеры updated_at; разбор «<МДО»; превышения ПДК; пакетная загрузка staging.

CREATE OR REPLACE FUNCTION eco.fn_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    t text;
    trg text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'sites', 'monitoring_points', 'laboratories', 'sampling_events',
        'samples', 'parameters', 'guideline_standards', 'guideline_values',
        'results', 'field_measurements', 'water_levels'
    ]
    LOOP
        trg := 'trg_' || t || '_updated_at';
        EXECUTE format(
            'DROP TRIGGER IF EXISTS %I ON eco.%I;
             CREATE TRIGGER %I
                 BEFORE UPDATE ON eco.%I
                 FOR EACH ROW
                 EXECUTE FUNCTION eco.fn_set_updated_at();',
            trg, t, trg, t
        );
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION eco.fn_norm_label(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT lower(btrim(
        regexp_replace(
            replace(replace(p_text, 'ё', 'е'), 'Ё', 'е'),
            '\s+',
            ' ',
            'g'
        )
    ));
$$;

CREATE OR REPLACE FUNCTION eco.fn_parse_lab_result(
    p_text      text,
    p_mdl       numeric,
    OUT o_value numeric,
    OUT o_less_than boolean,
    OUT o_error text
)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v text;
    nd_key text;
BEGIN
    o_less_than := false;
    o_value := NULL;
    o_error := NULL;

    IF p_text IS NULL OR btrim(p_text) = '' THEN
        o_error := 'Пустое значение результата';
        RETURN;
    END IF;

    v := btrim(p_text);
    v := replace(v, chr(160), ' ');
    v := replace(v, chr(8722), '-');

    nd_key := regexp_replace(eco.fn_norm_label(v), '[.\s]', '', 'g');
    IF nd_key IN (
        'необн', 'необнаружено', 'необнаруж',
        'н/о', 'но', 'nd', 'n/d', 'bdl', 'lod'
    ) THEN
        o_less_than := true;
        o_value := p_mdl;
        IF o_value IS NULL THEN
            o_error := 'Не задан МДО для значения ниже предела обнаружения';
        END IF;
        RETURN;
    END IF;

    v := regexp_replace(v, '\s+', '', 'g');
    v := replace(v, ',', '.');

    IF v ~ '^(<=|[<≤⩽])' THEN
        o_less_than := true;
        v := regexp_replace(v, '^(<=|[<≤⩽])', '');
        IF v = '' THEN
            o_value := p_mdl;
            IF o_value IS NULL THEN
                o_error := 'Не задан МДО для значения ниже предела обнаружения';
            END IF;
            RETURN;
        END IF;
    END IF;

    IF v ~ '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$' THEN
        o_value := v::numeric;
        RETURN;
    END IF;

    o_error := 'Не удалось разобрать значение результата: ' || p_text;
END;
$$;

CREATE OR REPLACE FUNCTION eco.fn_resolve_param_id(
    p_param_code    text,
    p_param_name    text,
    p_source        text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_id bigint;
    v_code text := NULLIF(btrim(p_param_code), '');
    v_name text := NULLIF(btrim(p_param_name), '');
    v_norm text;
BEGIN
    IF v_code IS NOT NULL THEN
        SELECT param_id INTO v_id
        FROM eco.parameters
        WHERE param_code = v_code
           OR lower(param_code) = lower(v_code);
        IF v_id IS NOT NULL THEN
            RETURN v_id;
        END IF;

        v_norm := eco.fn_norm_label(v_code);
        SELECT pa.param_id INTO v_id
        FROM eco.parameter_aliases pa
        WHERE pa.alias_norm = v_norm
          AND (p_source IS NULL OR pa.source_system IS NULL OR pa.source_system = p_source)
        ORDER BY CASE WHEN pa.source_system IS NOT DISTINCT FROM p_source THEN 0 ELSE 1 END
        LIMIT 1;
        IF v_id IS NOT NULL THEN
            RETURN v_id;
        END IF;
    END IF;

    IF v_name IS NOT NULL THEN
        SELECT param_id INTO v_id
        FROM eco.parameters
        WHERE eco.fn_norm_label(name_ru) = eco.fn_norm_label(v_name)
           OR (name_en IS NOT NULL AND eco.fn_norm_label(name_en) = eco.fn_norm_label(v_name));
        IF v_id IS NOT NULL THEN
            RETURN v_id;
        END IF;

        v_norm := eco.fn_norm_label(v_name);
        SELECT pa.param_id INTO v_id
        FROM eco.parameter_aliases pa
        WHERE pa.alias_norm = v_norm
          AND (p_source IS NULL OR pa.source_system IS NULL OR pa.source_system = p_source)
        ORDER BY CASE WHEN pa.source_system IS NOT DISTINCT FROM p_source THEN 0 ELSE 1 END
        LIMIT 1;
        IF v_id IS NOT NULL THEN
            RETURN v_id;
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION eco.fn_resolve_point_id(p_point_code text)
RETURNS bigint
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_id bigint;
    v_code text := NULLIF(btrim(p_point_code), '');
    v_norm text;
BEGIN
    IF v_code IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT point_id INTO v_id
    FROM eco.monitoring_points
    WHERE point_code = v_code
       OR lower(point_code) = lower(v_code);
    IF v_id IS NOT NULL THEN
        RETURN v_id;
    END IF;

    v_norm := eco.fn_norm_label(v_code);
    SELECT pa.point_id INTO v_id
    FROM eco.point_aliases pa
    WHERE pa.alias_norm = v_norm
    LIMIT 1;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION eco.fn_check_exceedances_for_result(p_result_id bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    rec         record;
    ctx         record;
    v_exceeds   boolean;
    v_limit     numeric;
    v_ratio     numeric;
    v_pct       numeric;
    keep_ids    bigint[] := ARRAY[]::bigint[];
BEGIN
    SELECT
        r.result_id,
        r.param_id,
        r.result_value,
        r.less_than,
        e.event_date,
        e.media_type
    INTO ctx
    FROM eco.results r
    JOIN eco.samples s ON s.sample_id = r.sample_id
    JOIN eco.sampling_events e ON e.event_id = s.event_id
    WHERE r.result_id = p_result_id;

    IF NOT FOUND OR ctx.result_value IS NULL THEN
        DELETE FROM eco.result_exceedances WHERE result_id = p_result_id;
        RETURN;
    END IF;

    FOR rec IN
        SELECT gv.gv_id, gv.standard_id, gv.comparison_op,
               gv.limit_value, gv.limit_min, gv.limit_max
        FROM eco.guideline_values gv
        JOIN eco.guideline_standards gs ON gs.standard_id = gv.standard_id
        WHERE gv.param_id = ctx.param_id
          AND gv.media_type = ctx.media_type
          AND gs.is_active
          AND ctx.event_date >= gv.valid_from
          AND (gv.valid_to IS NULL OR ctx.event_date <= gv.valid_to)
    LOOP
        v_exceeds := false;
        v_limit := COALESCE(rec.limit_value, rec.limit_max);

        IF rec.comparison_op = 'GT' THEN
            v_exceeds := ctx.result_value > rec.limit_value;
            v_limit := rec.limit_value;
        ELSIF rec.comparison_op = 'GTE' THEN
            v_exceeds := ctx.result_value >= rec.limit_value;
            v_limit := rec.limit_value;
        ELSIF rec.comparison_op = 'LT' THEN
            v_exceeds := ctx.result_value < rec.limit_value;
            v_limit := rec.limit_value;
        ELSIF rec.comparison_op = 'LTE' THEN
            v_exceeds := ctx.result_value <= rec.limit_value;
            v_limit := rec.limit_value;
        ELSIF rec.comparison_op = 'RANGE' THEN
            IF ctx.result_value < rec.limit_min THEN
                v_exceeds := true;
                v_limit := rec.limit_min;
            ELSIF ctx.result_value > rec.limit_max THEN
                v_exceeds := true;
                v_limit := rec.limit_max;
            END IF;
        END IF;

        IF ctx.less_than AND v_limit IS NOT NULL AND ctx.result_value <= v_limit THEN
            v_exceeds := false;
        END IF;

        IF v_exceeds AND v_limit IS NOT NULL AND v_limit <> 0 THEN
            v_ratio := ctx.result_value / v_limit;
            v_pct := (ctx.result_value - v_limit) / v_limit * 100.0;

            INSERT INTO eco.result_exceedances (
                result_id, gv_id, standard_id,
                limit_value_applied, ratio, exceedance_pct, detected_at
            )
            VALUES (
                p_result_id, rec.gv_id, rec.standard_id,
                v_limit, v_ratio, v_pct, now()
            )
            ON CONFLICT (result_id, gv_id) DO UPDATE
            SET standard_id         = EXCLUDED.standard_id,
                limit_value_applied = EXCLUDED.limit_value_applied,
                ratio               = EXCLUDED.ratio,
                exceedance_pct      = EXCLUDED.exceedance_pct,
                detected_at         = now();

            keep_ids := array_append(keep_ids, rec.gv_id);
        END IF;
    END LOOP;

    IF cardinality(keep_ids) = 0 THEN
        DELETE FROM eco.result_exceedances WHERE result_id = p_result_id;
    ELSE
        DELETE FROM eco.result_exceedances x
        WHERE x.result_id = p_result_id
          AND NOT (x.gv_id = ANY (keep_ids));
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION eco.fn_check_exceedances()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM eco.fn_check_exceedances_for_result(NEW.result_id);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_check_exceedances ON eco.results;
CREATE TRIGGER trg_check_exceedances
    AFTER INSERT OR UPDATE OF result_value, less_than, param_id, sample_id
    ON eco.results
    FOR EACH ROW
    EXECUTE FUNCTION eco.fn_check_exceedances();

CREATE OR REPLACE FUNCTION eco.fn_recalc_all_exceedances()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    rec record;
    n bigint := 0;
BEGIN
    FOR rec IN SELECT result_id FROM eco.results LOOP
        PERFORM eco.fn_check_exceedances_for_result(rec.result_id);
        n := n + 1;
    END LOOP;
    RETURN n;
END;
$$;

COMMENT ON FUNCTION eco.fn_recalc_all_exceedances() IS
  'Повторный расчёт превышений по всей таблице results (после загрузки истории или смены ПДК).';

CREATE OR REPLACE FUNCTION eco.fn_process_staging_import(p_batch_code text)
RETURNS TABLE (metric text, value bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    r               eco.staging_lab_import%ROWTYPE;
    v_ok            bigint := 0;
    v_err           bigint := 0;
    v_ins           bigint := 0;
    v_upd           bigint := 0;
    v_point_id      bigint;
    v_param_id      bigint;
    v_lab_id        bigint;
    v_site_id       bigint;
    v_media         text;
    v_event_id      bigint;
    v_sample_id     bigint;
    v_event_date    date;
    v_event_ts      timestamptz;
    v_parsed        record;
    v_unit          text;
    v_mdl           numeric;
    v_existed       boolean;
    v_sample_code   text;
    v_qc            char(1);
    v_mdl_store     numeric;
BEGIN
    IF p_batch_code IS NULL OR btrim(p_batch_code) = '' THEN
        RAISE EXCEPTION 'batch_code не задан';
    END IF;

    FOR r IN
        SELECT *
        FROM eco.staging_lab_import
        WHERE batch_code = p_batch_code
          AND processed_at IS NULL
        ORDER BY staging_id
    LOOP
        BEGIN
            v_point_id := eco.fn_resolve_point_id(r.point_code);
            IF v_point_id IS NULL THEN
                RAISE EXCEPTION 'Не найдена точка наблюдения: %', COALESCE(r.point_code, '(пусто)');
            END IF;

            v_param_id := eco.fn_resolve_param_id(r.param_code, r.param_name_raw, r.lab_code);
            IF v_param_id IS NULL THEN
                RAISE EXCEPTION 'Не найден показатель: %',
                    COALESCE(NULLIF(btrim(r.param_code), ''), NULLIF(btrim(r.param_name_raw), ''), '(пусто)');
            END IF;

            SELECT p.site_id, p.media_type
            INTO v_site_id, v_media
            FROM eco.monitoring_points p
            WHERE p.point_id = v_point_id;

            IF r.media_type IS NOT NULL AND btrim(r.media_type) <> '' THEN
                v_media := btrim(r.media_type);
                IF NOT EXISTS (SELECT 1 FROM eco.ref_media_types WHERE media_code = v_media) THEN
                    RAISE EXCEPTION 'Неизвестный тип среды: %', v_media;
                END IF;
            END IF;

            v_lab_id := NULL;
            IF r.lab_code IS NOT NULL AND btrim(r.lab_code) <> '' THEN
                SELECT lab_id INTO v_lab_id
                FROM eco.laboratories
                WHERE lab_code = btrim(r.lab_code)
                   OR lower(lab_code) = lower(btrim(r.lab_code));
                IF v_lab_id IS NULL THEN
                    RAISE EXCEPTION 'Не найдена лаборатория: %', r.lab_code;
                END IF;
            END IF;

            v_event_ts := r.collection_datetime;
            v_event_date := COALESCE(r.collection_date, (r.collection_datetime)::date);
            IF v_event_date IS NULL AND r.year_num IS NOT NULL THEN
                v_event_date := make_date(
                    r.year_num,
                    CASE COALESCE(r.quarter_num, 1)
                        WHEN 1 THEN 1 WHEN 2 THEN 4 WHEN 3 THEN 7 ELSE 10
                    END,
                    1
                );
            END IF;
            IF v_event_date IS NULL THEN
                RAISE EXCEPTION 'Не указана дата отбора';
            END IF;

            INSERT INTO eco.sampling_events (
                site_id, point_id, event_date, event_datetime, media_type
            )
            VALUES (v_site_id, v_point_id, v_event_date, v_event_ts, v_media)
            ON CONFLICT (point_id, event_date, media_type) DO UPDATE
            SET event_datetime = COALESCE(EXCLUDED.event_datetime, eco.sampling_events.event_datetime),
                site_id        = EXCLUDED.site_id
            RETURNING event_id INTO v_event_id;

            v_sample_code := NULLIF(btrim(r.sample_code), '');

            SELECT s.sample_id INTO v_sample_id
            FROM eco.samples s
            WHERE s.event_id = v_event_id
              AND COALESCE(s.lab_id, -1) = COALESCE(v_lab_id, -1)
              AND COALESCE(s.sample_code, '') = COALESCE(v_sample_code, '');

            IF v_sample_id IS NULL THEN
                INSERT INTO eco.samples (
                    event_id, lab_id, sample_code, collection_datetime
                )
                VALUES (
                    v_event_id, v_lab_id, v_sample_code,
                    COALESCE(v_event_ts, v_event_date::timestamp)
                )
                RETURNING sample_id INTO v_sample_id;
            ELSE
                UPDATE eco.samples
                SET collection_datetime = COALESCE(v_event_ts, collection_datetime)
                WHERE sample_id = v_sample_id;
            END IF;

            SELECT unit, mdl_default INTO v_unit, v_mdl
            FROM eco.parameters
            WHERE param_id = v_param_id;

            SELECT * INTO v_parsed
            FROM eco.fn_parse_lab_result(r.result_text, v_mdl);

            IF v_parsed.o_error IS NOT NULL THEN
                RAISE EXCEPTION '%', v_parsed.o_error;
            END IF;

            v_qc := CASE WHEN v_parsed.o_less_than THEN 'B' ELSE 'C' END;
            v_mdl_store := CASE
                WHEN v_parsed.o_less_than THEN v_parsed.o_value
                ELSE v_mdl
            END;

            SELECT EXISTS (
                SELECT 1 FROM eco.results
                WHERE sample_id = v_sample_id AND param_id = v_param_id
            ) INTO v_existed;

            INSERT INTO eco.results (
                sample_id, param_id, result_value, less_than, unit, mdl, qc_code
            )
            VALUES (
                v_sample_id, v_param_id,
                v_parsed.o_value, v_parsed.o_less_than,
                COALESCE(NULLIF(btrim(r.unit_raw), ''), v_unit),
                v_mdl_store,
                v_qc
            )
            ON CONFLICT (sample_id, param_id) DO UPDATE
            SET result_value = EXCLUDED.result_value,
                less_than    = EXCLUDED.less_than,
                unit         = EXCLUDED.unit,
                mdl          = EXCLUDED.mdl,
                qc_code      = EXCLUDED.qc_code;

            UPDATE eco.staging_lab_import
            SET processed_at = now(),
                process_error = NULL
            WHERE staging_id = r.staging_id;

            v_ok := v_ok + 1;
            IF v_existed THEN
                v_upd := v_upd + 1;
            ELSE
                v_ins := v_ins + 1;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            UPDATE eco.staging_lab_import
            SET process_error = SQLERRM
            WHERE staging_id = r.staging_id;
            v_err := v_err + 1;
        END;
    END LOOP;

    metric := 'processed_ok';      value := v_ok;  RETURN NEXT;
    metric := 'processed_error';   value := v_err; RETURN NEXT;
    metric := 'results_inserted';  value := v_ins; RETURN NEXT;
    metric := 'results_updated';   value := v_upd; RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION eco.fn_process_staging_import(text) IS
  'Обрабатывает необработанные строки партии staging_lab_import: маппинг кодов, разбор <МДО, upsert events/samples/results.';

INSERT INTO eco.schema_migrations (version, description)
VALUES ('004', 'Функции, триггеры updated_at и trg_check_exceedances, ETL staging')
ON CONFLICT (version) DO NOTHING;
