-- Phase 3 checks. Does not roll back. Air pilot rows must still be present.

DO $$
DECLARE
    n int;
BEGIN
    SELECT count(*) INTO n FROM eco.monitoring_points WHERE media_type = 'surface_water';
    IF n <> 4 THEN RAISE EXCEPTION 'expected 4 surface points, got %', n; END IF;

    SELECT count(*) INTO n FROM eco.monitoring_points WHERE media_type = 'groundwater';
    IF n <> 14 THEN RAISE EXCEPTION 'expected 14 groundwater points, got %', n; END IF;

    SELECT count(*) INTO n FROM eco.staging_lab_import WHERE batch_code = 'WATER_SURFACE_2025';
    IF n <> 62 THEN RAISE EXCEPTION 'expected 62 surface staging rows, got %', n; END IF;

    SELECT count(*) INTO n
    FROM eco.staging_lab_import
    WHERE batch_code = 'WATER_SURFACE_2025' AND process_error IS NOT NULL;
    IF n <> 0 THEN RAISE EXCEPTION 'surface batch errors: %', n; END IF;

    SELECT count(*) INTO n FROM eco.staging_lab_import WHERE batch_code = 'WATER_GROUND_2025';
    IF n <> 230 THEN RAISE EXCEPTION 'expected 230 ground staging rows, got %', n; END IF;

    SELECT count(*) INTO n
    FROM eco.staging_lab_import
    WHERE batch_code = 'WATER_GROUND_2025'
      AND process_error LIKE 'Значение не измерено%';
    IF n <> 115 THEN RAISE EXCEPTION 'expected 115 «нет» ground rows, got %', n; END IF;

    SELECT count(*) INTO n FROM eco.staging_lab_import WHERE batch_code = 'WATER_WELLS_PDF';
    IF n <> 39 THEN RAISE EXCEPTION 'expected 39 well rows, got %', n; END IF;

    SELECT count(*) INTO n
    FROM eco.staging_lab_import
    WHERE batch_code = 'WATER_WELLS_PDF' AND processed_at IS NULL;
    IF n <> 0 THEN RAISE EXCEPTION 'unprocessed well rows: %', n; END IF;

    SELECT count(*) INTO n
    FROM eco.results r
    JOIN eco.samples sm ON sm.sample_id = r.sample_id
    JOIN eco.sampling_events e ON e.event_id = sm.event_id
    WHERE e.media_type = 'surface_water';
    IF n <> 62 THEN RAISE EXCEPTION 'expected 62 surface results, got %', n; END IF;

    SELECT count(*) INTO n
    FROM eco.results r
    JOIN eco.samples sm ON sm.sample_id = r.sample_id
    JOIN eco.sampling_events e ON e.event_id = sm.event_id
    JOIN eco.monitoring_points p ON p.point_id = e.point_id
    WHERE p.point_code LIKE 'GW-%';
    IF n <> 115 THEN RAISE EXCEPTION 'expected 115 GW results, got %', n; END IF;

    SELECT count(*) INTO n
    FROM eco.results r
    JOIN eco.samples sm ON sm.sample_id = r.sample_id
    JOIN eco.sampling_events e ON e.event_id = sm.event_id
    JOIN eco.monitoring_points p ON p.point_id = e.point_id
    WHERE p.point_code IN ('ФС-1', 'ФС-4', 'ФС-5', 'НС-2');
    IF n <> 39 THEN RAISE EXCEPTION 'expected 39 well results, got %', n; END IF;

    SELECT count(*) INTO n
    FROM eco.results r
    JOIN eco.parameters pr ON pr.param_id = r.param_id
    WHERE pr.param_code = 'CN' AND r.less_than;
    IF n < 3 THEN RAISE EXCEPTION 'expected CN non-detects from PDF, got %', n; END IF;

    SELECT count(*) INTO n
    FROM eco.result_exceedances x
    JOIN eco.results r ON r.result_id = x.result_id
    JOIN eco.samples sm ON sm.sample_id = r.sample_id
    JOIN eco.sampling_events e ON e.event_id = sm.event_id
    WHERE e.media_type = 'surface_water';
    IF n <> 3 THEN RAISE EXCEPTION 'expected 3 surface exceedances (Fe x2, pH x1), got %', n; END IF;

    SELECT count(*) INTO n
    FROM eco.results r
    JOIN eco.samples sm ON sm.sample_id = r.sample_id
    JOIN eco.sampling_events e ON e.event_id = sm.event_id
    WHERE e.media_type = 'air';
    IF n <> 2736 THEN RAISE EXCEPTION 'air pilot changed: %', n; END IF;
END;
$$;

SELECT 'phase3 checks passed' AS status;
