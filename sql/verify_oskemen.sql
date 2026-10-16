-- Checks after python3 etl/load_oskemen_stations.py (does not roll back).

DO $$
DECLARE
    n int;
    n_join int;
    n_all bigint;
    n_key bigint;
BEGIN
    SELECT count(*) INTO n
    FROM eco.monitoring_points
    WHERE point_type = 'автостанция' AND geom IS NOT NULL;
    IF n <> 13 THEN
        RAISE EXCEPTION 'expected 13 kgmt points with geom, got %', n;
    END IF;

    SELECT count(*) INTO n FROM eco.parameters WHERE group_name = 'kgmt' AND unit = 'ug/m3';
    IF n <> 9 THEN
        RAISE EXCEPTION 'expected 9 kgmt parameters in ug/m3, got %', n;
    END IF;

    SELECT count(*) INTO n
    FROM eco.results r
    JOIN eco.samples s ON s.sample_id = r.sample_id
    WHERE s.sample_type = 'hourly_sensor';
    IF n < 1000000 THEN
        RAISE EXCEPTION 'expected at least 1e6 hourly results, got %', n;
    END IF;

    SELECT count(*) INTO n FROM eco.meteo_observations;
    IF n < 600000 THEN
        RAISE EXCEPTION 'expected at least 600k meteo hours, got %', n;
    END IF;

    SELECT count(*) INTO n
    FROM eco.results r
    JOIN eco.samples s ON s.sample_id = r.sample_id
    WHERE s.sample_type = 'hourly_sensor'
      AND r.unit IS DISTINCT FROM 'ug/m3';
    IF n <> 0 THEN
        RAISE EXCEPTION '% hourly results not in ug/m3', n;
    END IF;

    SELECT count(*) INTO n_join
    FROM eco.vw_sensor_hourly
    WHERE meteo_id IS NOT NULL;
    IF n_join < 1000000 THEN
        RAISE EXCEPTION 'expected pollutant–meteo join on (point, hour), got % matched', n_join;
    END IF;

    SELECT count(*), count(DISTINCT objectid) INTO n_all, n_key FROM eco.vw_sensor_latest;
    IF n_all = 0 OR n_all <> n_key THEN
        RAISE EXCEPTION 'vw_sensor_latest empty or objectid not unique (% / %)', n_all, n_key;
    END IF;

    SELECT count(*) INTO n FROM eco.vw_sensor_latest_wide WHERE geom IS NOT NULL;
    IF n <> 13 THEN
        RAISE EXCEPTION 'vw_sensor_latest_wide expected 13 geoms, got %', n;
    END IF;
END
$$;

SELECT 'oskemen station load checks passed' AS status;
SELECT count(*) AS hourly_results
FROM eco.results r
JOIN eco.samples s ON s.sample_id = r.sample_id
WHERE s.sample_type = 'hourly_sensor';
SELECT count(*) AS meteo_rows FROM eco.meteo_observations;
SELECT count(*) AS latest_rows FROM eco.vw_sensor_latest;
SELECT count(*) AS latest_stations FROM eco.vw_sensor_latest_wide;
