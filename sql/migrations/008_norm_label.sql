-- 008_norm_label.sql
-- lower() при lc_ctype=C не трогает кириллицу, из-за этого синонимы не сходились.

CREATE OR REPLACE FUNCTION eco.fn_norm_label(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT translate(
        lower(btrim(regexp_replace(
            replace(replace(p_text, 'ё', 'е'), 'Ё', 'е'),
            '\s+', ' ', 'g'
        ))),
        'АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ',
        'абвгдежзийклмнопрстуфхцчшщъыьэюя'
    );
$$;

INSERT INTO eco.schema_migrations (version, description)
VALUES ('008', 'Нормализация подписей: нижний регистр кириллицы при lc_ctype=C')
ON CONFLICT (version) DO NOTHING;
