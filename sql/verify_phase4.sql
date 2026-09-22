-- Phase 4 checks against the latest finished QA run. Does not roll back.

DO $$
DECLARE
    v_run bigint;
    n bigint;
    n_results bigint;
    n_sample bigint;
BEGIN
    SELECT qa_run_id INTO v_run
    FROM eco.qa_runs
    WHERE finished_at IS NOT NULL
    ORDER BY qa_run_id DESC
    LIMIT 1;
    IF v_run IS NULL THEN
        RAISE EXCEPTION 'no finished QA run';
    END IF;

    SELECT count(*) INTO n
    FROM eco.qa_findings
    WHERE qa_run_id = v_run AND severity = 'error';
    IF n <> 0 THEN
        RAISE EXCEPTION 'QA run % has % error findings', v_run, n;
    END IF;

    SELECT count(*) INTO n_results FROM eco.results;
    SELECT count(*) INTO n FROM eco.results WHERE qc_code IS NULL OR qc_reason IS NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION '% results without qc_code/qc_reason', n;
    END IF;

    SELECT count(DISTINCT result_id) INTO n_sample
    FROM eco.qa_spot_checks
    WHERE qa_run_id = v_run AND sample_kind = 'random_5pct';
    IF n_sample < ceil(n_results * 0.05) THEN
        RAISE EXCEPTION 'random sample % is below 5%% of %', n_sample, n_results;
    END IF;

    SELECT count(*) INTO n
    FROM eco.qa_spot_checks
    WHERE qa_run_id = v_run
      AND sample_kind = 'protocol'
      AND disposition = 'mismatch';
    IF n <> 0 THEN
        RAISE EXCEPTION 'protocol mismatches: %', n;
    END IF;

    SELECT count(*) INTO n
    FROM eco.results r
    JOIN eco.parameters p ON p.param_id = r.param_id
    WHERE p.param_code = 'HCN'
      AND r.qc_reason = 'imputed_nondetect'
      AND r.qc_code <> 'R';
    IF n <> 0 THEN
        RAISE EXCEPTION 'imputed HCN not marked R: %', n;
    END IF;
END;
$$;

SELECT 'phase4 checks passed' AS status;

SELECT qc_code, count(*) FROM eco.results GROUP BY 1 ORDER BY 1;
