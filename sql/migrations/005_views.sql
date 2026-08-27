-- 005_views.sql
-- Представления для регистрации в ArcGIS Enterprise как Query Layer.
-- objectid — уникальный integer/bigint; geom — Point 4326; NULL geom допустим.

CREATE OR REPLACE VIEW eco.vw_results_flat AS
SELECT
    r.result_id                                                     AS objectid,
    r.result_id,
    r.sample_id,
    s.event_id,
    e.site_id,
    si.site_code,
    si.name_ru                                                      AS site_name_ru,
    e.point_id,
    p.point_code,
    p.name_ru                                                       AS point_name_ru,
    e.media_type,
    p.geom,
    s.lab_id,
    l.lab_code,
    l.name_ru                                                       AS lab_name_ru,
    s.sample_code,
    s.coc_number,
    e.event_date,
    s.collection_datetime,
    r.param_id,
    pr.param_code,
    pr.name_ru                                                      AS param_name_ru,
    pr.name_en                                                      AS param_name_en,
    COALESCE(r.unit, pr.unit)                                       AS unit,
    r.result_value,
    r.less_than,
    r.mdl,
    r.qc_code,
    r.lab_method,
    r.analysis_datetime,
    EXISTS (
        SELECT 1 FROM eco.result_exceedances x WHERE x.result_id = r.result_id
    )                                                               AS has_exceedance,
    (
        SELECT max(x.ratio)
        FROM eco.result_exceedances x
        WHERE x.result_id = r.result_id
    )                                                               AS max_exceedance_ratio,
    r.comments,
    r.created_at
FROM eco.results r
JOIN eco.samples s              ON s.sample_id = r.sample_id
JOIN eco.sampling_events e      ON e.event_id = s.event_id
JOIN eco.monitoring_points p    ON p.point_id = e.point_id
JOIN eco.sites si               ON si.site_id = e.site_id
JOIN eco.parameters pr          ON pr.param_id = r.param_id
LEFT JOIN eco.laboratories l    ON l.lab_id = s.lab_id;

COMMENT ON VIEW eco.vw_results_flat IS
  'Плоский слой результатов с геометрией точки. Query Layer: уникальный ключ objectid = result_id.';

CREATE OR REPLACE VIEW eco.vw_exceedances_summary AS
SELECT
    x.exceedance_id                                                 AS objectid,
    x.exceedance_id,
    x.result_id,
    x.gv_id,
    x.standard_id,
    gs.standard_code,
    gs.name_ru                                                      AS standard_name_ru,
    e.site_id,
    si.site_code,
    si.name_ru                                                      AS site_name_ru,
    e.point_id,
    p.point_code,
    p.name_ru                                                       AS point_name_ru,
    e.media_type,
    p.geom,
    e.event_date,
    s.collection_datetime,
    r.param_id,
    pr.param_code,
    pr.name_ru                                                      AS param_name_ru,
    pr.name_en                                                      AS param_name_en,
    COALESCE(r.unit, pr.unit)                                       AS unit,
    r.result_value,
    r.less_than,
    r.qc_code,
    x.limit_value_applied,
    x.ratio,
    x.exceedance_pct,
    x.detected_at
FROM eco.result_exceedances x
JOIN eco.results r              ON r.result_id = x.result_id
JOIN eco.samples s              ON s.sample_id = r.sample_id
JOIN eco.sampling_events e      ON e.event_id = s.event_id
JOIN eco.monitoring_points p    ON p.point_id = e.point_id
JOIN eco.sites si               ON si.site_id = e.site_id
JOIN eco.parameters pr          ON pr.param_id = r.param_id
JOIN eco.guideline_standards gs ON gs.standard_id = x.standard_id;

COMMENT ON VIEW eco.vw_exceedances_summary IS
  'Слой превышений нормативов (одна запись на result + норматив) с геометрией точки.';

CREATE OR REPLACE VIEW eco.vw_latest_results AS
SELECT
    q.objectid,
    q.result_id,
    q.sample_id,
    q.event_id,
    q.site_id,
    q.site_code,
    q.site_name_ru,
    q.point_id,
    q.point_code,
    q.point_name_ru,
    q.media_type,
    q.geom,
    q.lab_code,
    q.event_date,
    q.collection_datetime,
    q.param_id,
    q.param_code,
    q.param_name_ru,
    q.param_name_en,
    q.unit,
    q.result_value,
    q.less_than,
    q.mdl,
    q.qc_code,
    q.has_exceedance,
    q.max_exceedance_ratio
FROM (
    SELECT DISTINCT ON (e.point_id, r.param_id)
        r.result_id                                                 AS objectid,
        r.result_id,
        r.sample_id,
        s.event_id,
        e.site_id,
        si.site_code,
        si.name_ru                                                  AS site_name_ru,
        e.point_id,
        p.point_code,
        p.name_ru                                                   AS point_name_ru,
        e.media_type,
        p.geom,
        l.lab_code,
        e.event_date,
        s.collection_datetime,
        r.param_id,
        pr.param_code,
        pr.name_ru                                                  AS param_name_ru,
        pr.name_en                                                  AS param_name_en,
        COALESCE(r.unit, pr.unit)                                   AS unit,
        r.result_value,
        r.less_than,
        r.mdl,
        r.qc_code,
        EXISTS (
            SELECT 1 FROM eco.result_exceedances x WHERE x.result_id = r.result_id
        )                                                           AS has_exceedance,
        (
            SELECT max(x.ratio)
            FROM eco.result_exceedances x
            WHERE x.result_id = r.result_id
        )                                                           AS max_exceedance_ratio
    FROM eco.results r
    JOIN eco.samples s              ON s.sample_id = r.sample_id
    JOIN eco.sampling_events e      ON e.event_id = s.event_id
    JOIN eco.monitoring_points p    ON p.point_id = e.point_id
    JOIN eco.sites si               ON si.site_id = e.site_id
    JOIN eco.parameters pr          ON pr.param_id = r.param_id
    LEFT JOIN eco.laboratories l    ON l.lab_id = s.lab_id
    LEFT JOIN eco.ref_qc_codes qc   ON qc.qc_code = r.qc_code
    WHERE r.qc_code IS NULL
       OR qc.include_in_latest IS TRUE
    ORDER BY
        e.point_id,
        r.param_id,
        COALESCE(s.collection_datetime, e.event_datetime, e.event_date::timestamp) DESC,
        r.result_id DESC
) q;

COMMENT ON VIEW eco.vw_latest_results IS
  'Последний результат по паре (точка, показатель). Исключены коды QC = D и R.';

CREATE OR REPLACE VIEW eco.vw_water_levels AS
SELECT
    w.level_id                                                      AS objectid,
    w.level_id,
    w.point_id,
    p.point_code,
    p.name_ru                                                       AS point_name_ru,
    p.site_id,
    si.site_code,
    si.name_ru                                                      AS site_name_ru,
    p.geom,
    w.measured_datetime,
    w.depth_to_water_m,
    w.water_elevation_m,
    w.measuring_point_elevation_m,
    w.comments,
    w.created_at
FROM eco.water_levels w
JOIN eco.monitoring_points p ON p.point_id = w.point_id
JOIN eco.sites si            ON si.site_id = p.site_id;

COMMENT ON VIEW eco.vw_water_levels IS
  'Уровни подземных вод с геометрией скважины. Query Layer: objectid = level_id.';

GRANT USAGE ON SCHEMA eco TO PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA eco TO PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA eco GRANT SELECT ON TABLES TO PUBLIC;

INSERT INTO eco.schema_migrations (version, description)
VALUES ('005', 'Представления ArcGIS Query Layer и права SELECT')
ON CONFLICT (version) DO NOTHING;
