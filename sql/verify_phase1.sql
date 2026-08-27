-- Smoke-test Phase 1 against an empty schema. Always ROLLBACK.
BEGIN;

INSERT INTO eco.sites (site_code, name_ru) VALUES ('SITE1', 'Тестовый объект');

INSERT INTO eco.monitoring_points (point_code, site_id, name_ru, media_type, geom)
SELECT 'Т-6', site_id, 'Точка Т-6', 'air',
       ST_SetSRID(ST_MakePoint(76.9, 43.2), 4326)
FROM eco.sites WHERE site_code = 'SITE1';

INSERT INTO eco.laboratories (lab_code, name_ru) VALUES ('LAB1', 'Тестовая лаборатория');

INSERT INTO eco.parameters (param_code, name_ru, name_en, unit, media_type, mdl_default)
VALUES ('Dust', 'Пыль неорганическая', 'Inorganic dust', 'mg/m3', 'air', 0.01);

INSERT INTO eco.parameter_aliases (param_id, alias_norm, source_system)
SELECT param_id, eco.fn_norm_label('Пыль неорганическая'), 'PEK'
FROM eco.parameters WHERE param_code = 'Dust';

INSERT INTO eco.guideline_standards (standard_code, name_ru, media_type)
VALUES ('PDK_MR_AIR', 'ПДК максимально разовая, воздух', 'air');

INSERT INTO eco.guideline_values (
    standard_id, param_id, media_type, comparison_op, limit_value, valid_from
)
SELECT s.standard_id, p.param_id, 'air', 'GT', 0.3, DATE '2020-01-01'
FROM eco.guideline_standards s, eco.parameters p
WHERE s.standard_code = 'PDK_MR_AIR' AND p.param_code = 'Dust';

INSERT INTO eco.staging_lab_import (
    batch_code, source_file, row_no, lab_code, point_code, param_name_raw,
    collection_date, result_text, media_type
) VALUES
    ('AIR_PILOT', 'test.xlsx', 1, 'LAB1', 'Т-6', 'Пыль неорганическая',
     DATE '2020-03-17', '1.53', 'air'),
    ('AIR_PILOT', 'test.xlsx', 2, 'LAB1', 'Т-6', 'Пыль неорганическая',
     DATE '2020-03-17', '<0.01', 'air'),
    ('AIR_PILOT', 'test.xlsx', 3, 'LAB1', 'UNKNOWN', 'Пыль неорганическая',
     DATE '2020-03-17', '0.1', 'air');

SELECT * FROM eco.fn_process_staging_import('AIR_PILOT');

DO $$
DECLARE
    v_results int;
    v_exc int;
    v_err int;
    v_lt boolean;
    v_ratio numeric;
BEGIN
    SELECT count(*) INTO v_results FROM eco.results;
    SELECT count(*) INTO v_exc FROM eco.result_exceedances;
    SELECT count(*) INTO v_err FROM eco.staging_lab_import WHERE process_error IS NOT NULL;

    IF v_results <> 1 THEN
        RAISE EXCEPTION 'expected 1 result after upsert, got %', v_results;
    END IF;
    IF v_err <> 1 THEN
        RAISE EXCEPTION 'expected 1 staging error (unknown point), got %', v_err;
    END IF;

    -- Last staging row for Т-6 is <0.01 and overwrites 1.53; exceedance should be gone.
    SELECT less_than INTO v_lt FROM eco.results;
    IF v_lt IS NOT TRUE THEN
        RAISE EXCEPTION 'second row should set less_than after upsert';
    END IF;
    IF v_exc <> 0 THEN
        RAISE EXCEPTION 'non-detect below PDK must not create exceedance, got %', v_exc;
    END IF;
END;
$$;

-- Reprocess a new batch with exceedance only
INSERT INTO eco.staging_lab_import (
    batch_code, source_file, row_no, lab_code, point_code, param_name_raw,
    collection_date, result_text, media_type
) VALUES
    ('AIR_EXC', 'test.xlsx', 1, 'LAB1', 'Т-6', 'Пыль неорганическая',
     DATE '2020-06-01', '1.53', 'air');

SELECT * FROM eco.fn_process_staging_import('AIR_EXC');

DO $$
DECLARE
    v_exc int;
    v_ratio numeric;
    v_view int;
BEGIN
    SELECT count(*), max(ratio) INTO v_exc, v_ratio FROM eco.result_exceedances;
    IF v_exc <> 1 THEN
        RAISE EXCEPTION 'expected 1 exceedance, got %', v_exc;
    END IF;
    IF round(v_ratio, 2) <> 5.10 THEN
        RAISE EXCEPTION 'expected ratio 5.10 (1.53/0.3), got %', v_ratio;
    END IF;

    SELECT count(*) INTO v_view FROM eco.vw_results_flat WHERE has_exceedance;
    IF v_view < 1 THEN
        RAISE EXCEPTION 'vw_results_flat has no exceedance rows';
    END IF;
    SELECT count(*) INTO v_view FROM eco.vw_exceedances_summary;
    IF v_view <> 1 THEN
        RAISE EXCEPTION 'vw_exceedances_summary expected 1 row, got %', v_view;
    END IF;
    SELECT count(*) INTO v_view FROM eco.vw_latest_results;
    IF v_view <> 1 THEN
        RAISE EXCEPTION 'vw_latest_results expected 1 row, got %', v_view;
    END IF;
END;
$$;

SELECT 'phase1 smoke test passed' AS status;

ROLLBACK;
