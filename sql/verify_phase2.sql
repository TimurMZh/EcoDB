-- Phase 2 checks against a loaded AIR_PILOT (does not roll back).

DO $$
DECLARE
    n int;
BEGIN
    SELECT count(*) INTO n FROM eco.sites WHERE site_code = 'OSK';
    IF n <> 1 THEN RAISE EXCEPTION 'expected site OSK'; END IF;

    SELECT count(*) INTO n FROM eco.monitoring_points WHERE media_type = 'air';
    IF n <> 30 THEN RAISE EXCEPTION 'expected 30 air points, got %', n; END IF;

    SELECT count(*) INTO n FROM eco.parameters WHERE media_type = 'air';
    IF n < 5 THEN RAISE EXCEPTION 'expected ≥5 air parameters, got %', n; END IF;

    SELECT count(*) INTO n FROM eco.staging_lab_import WHERE batch_code = 'AIR_PILOT';
    IF n <> 3600 THEN RAISE EXCEPTION 'expected 3600 staging rows, got %', n; END IF;

    SELECT count(*) INTO n FROM eco.staging_lab_import
    WHERE batch_code = 'AIR_PILOT' AND processed_at IS NOT NULL;
    IF n <> 2736 THEN
        RAISE EXCEPTION 'expected 2736 processed staging rows (3600−864 empty non-HCN), got %', n;
    END IF;

    SELECT count(*) INTO n FROM eco.results r
    JOIN eco.samples sm ON sm.sample_id = r.sample_id
    JOIN eco.sampling_events e ON e.event_id = sm.event_id
    WHERE e.media_type = 'air';
    IF n <> 2736 THEN RAISE EXCEPTION 'expected 2736 air results, got %', n; END IF;

    SELECT count(*) INTO n FROM eco.results r
    JOIN eco.parameters p ON p.param_id = r.param_id
    WHERE p.param_code = 'HCN' AND r.less_than;
    IF n <> 720 THEN RAISE EXCEPTION 'expected 720 HCN non-detects, got %', n; END IF;

    SELECT count(*) INTO n FROM eco.result_exceedances;
    IF n < 1 THEN RAISE EXCEPTION 'expected at least one exceedance'; END IF;

    SELECT count(*) INTO n FROM eco.vw_results_flat WHERE media_type = 'air';
    IF n <> 2736 THEN RAISE EXCEPTION 'vw_results_flat air rows %, expected 2736', n; END IF;
END;
$$;

SELECT 'phase2 checks passed' AS status;
SELECT count(*) AS air_results FROM eco.vw_results_flat WHERE media_type = 'air';
SELECT count(*) AS exceedances FROM eco.vw_exceedances_summary;
SELECT count(*) AS latest FROM eco.vw_latest_results WHERE media_type = 'air';
