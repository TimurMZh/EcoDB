-- Phase 5: Query Layer contract and the 3-second response check (TZ 7.3, 7.4).
-- Does not register layers in ArcGIS Enterprise. That step is in docs/ops-handover.md.

DO $$
DECLARE
    v_view text;
    n_all bigint;
    n_key bigint;
    n_bad_qc bigint;
    n_r bigint;
    t0 timestamptz;
    elapsed_ms numeric;
    n_rows bigint;
BEGIN
    FOREACH v_view IN ARRAY ARRAY[
        'vw_results_flat',
        'vw_exceedances_summary',
        'vw_latest_results',
        'vw_water_levels'
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = 'eco'
              AND table_name = v_view
              AND column_name = 'objectid'
        ) THEN
            RAISE EXCEPTION '% has no objectid', v_view;
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = 'eco'
              AND table_name = v_view
              AND column_name = 'geom'
              AND udt_name = 'geometry'
        ) THEN
            RAISE EXCEPTION '% has no geometry column geom', v_view;
        END IF;
    END LOOP;

    FOR v_view IN
        SELECT unnest(ARRAY[
            'vw_results_flat',
            'vw_exceedances_summary',
            'vw_latest_results',
            'vw_water_levels'
        ])
    LOOP
        EXECUTE format('SELECT count(*), count(DISTINCT objectid) FROM eco.%I', v_view)
            INTO n_all, n_key;
        IF n_all <> n_key THEN
            RAISE EXCEPTION '% objectid is not unique (% rows, % keys)', v_view, n_all, n_key;
        END IF;
        RAISE NOTICE '%: % rows, objectid unique', v_view, n_all;
    END LOOP;

    SELECT count(*) INTO n_bad_qc
    FROM eco.vw_latest_results
    WHERE qc_code IN ('D', 'R');
    IF n_bad_qc <> 0 THEN
        RAISE EXCEPTION 'vw_latest_results contains % rows with QC D or R', n_bad_qc;
    END IF;

    SELECT count(*) INTO n_r FROM eco.results WHERE qc_code = 'R';
    IF n_r > 0 THEN
        PERFORM 1
        FROM eco.results r
        WHERE r.qc_code = 'R'
          AND r.result_id IN (SELECT result_id FROM eco.vw_latest_results)
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'an R-coded result is visible in vw_latest_results';
        END IF;
    END IF;

    t0 := clock_timestamp();
    SELECT count(*) INTO n_rows
    FROM eco.vw_results_flat
    WHERE site_code = 'OSK'
      AND event_date BETWEEN DATE '2020-01-01' AND DATE '2025-12-31';
    elapsed_ms := extract(epoch FROM (clock_timestamp() - t0)) * 1000;
    RAISE NOTICE 'vw_results_flat OSK 2020-2025: % rows in % ms', n_rows, round(elapsed_ms, 1);
    IF elapsed_ms > 3000 THEN
        RAISE EXCEPTION 'vw_results_flat exceeded 3000 ms (% ms)', round(elapsed_ms, 1);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'eco_gis') THEN
        RAISE EXCEPTION 'role eco_gis is missing; apply migration 010';
    END IF;
    IF NOT has_schema_privilege('eco_gis', 'eco', 'USAGE')
       OR NOT has_table_privilege('eco_gis', 'eco.vw_results_flat', 'SELECT')
       OR NOT has_table_privilege('eco_gis', 'eco.vw_latest_results', 'SELECT') THEN
        RAISE EXCEPTION 'eco_gis cannot SELECT the ArcGIS views';
    END IF;
END
$$;

SELECT 'phase5 checks passed' AS status;
