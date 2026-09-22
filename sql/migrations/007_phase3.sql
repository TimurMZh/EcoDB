-- 007_phase3.sql
-- «нет» в отчётах — отсутствие измерения, не «ниже МДО».

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
    IF nd_key IN ('нет', 'н/д', 'неизмерено', 'неизмерялось', 'na', 'n/a') THEN
        o_error := 'Значение не измерено (' || btrim(p_text) || ')';
        RETURN;
    END IF;

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

INSERT INTO eco.schema_migrations (version, description)
VALUES ('007', 'Разбор «нет» как отсутствие измерения, не как <МДО')
ON CONFLICT (version) DO NOTHING;
