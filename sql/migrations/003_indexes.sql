-- 003_indexes.sql
-- GIST по geom; btree по датам, FK и уникальным ключам, используемым ETL и представлениями.

CREATE INDEX idx_monitoring_points_site
    ON eco.monitoring_points (site_id);

CREATE INDEX idx_monitoring_points_media
    ON eco.monitoring_points (media_type);

CREATE INDEX idx_monitoring_points_geom
    ON eco.monitoring_points USING GIST (geom)
    WHERE geom IS NOT NULL;

CREATE INDEX idx_point_aliases_point
    ON eco.point_aliases (point_id);

CREATE UNIQUE INDEX uq_point_aliases_norm
    ON eco.point_aliases (alias_norm, COALESCE(source_system, ''));

CREATE INDEX idx_sampling_events_site
    ON eco.sampling_events (site_id);

CREATE INDEX idx_sampling_events_point_date
    ON eco.sampling_events (point_id, event_date);

CREATE INDEX idx_sampling_events_date
    ON eco.sampling_events (event_date);

CREATE INDEX idx_samples_event
    ON eco.samples (event_id);

CREATE INDEX idx_samples_lab
    ON eco.samples (lab_id);

CREATE INDEX idx_samples_collection_datetime
    ON eco.samples (collection_datetime);

CREATE UNIQUE INDEX uq_samples_event_lab_code
    ON eco.samples (event_id, COALESCE(lab_id, -1), COALESCE(sample_code, ''));

CREATE INDEX idx_parameter_aliases_param
    ON eco.parameter_aliases (param_id);

CREATE UNIQUE INDEX uq_parameter_aliases_norm
    ON eco.parameter_aliases (alias_norm, COALESCE(source_system, ''));

CREATE INDEX idx_guideline_values_param
    ON eco.guideline_values (param_id);

CREATE INDEX idx_guideline_values_media_param
    ON eco.guideline_values (media_type, param_id, valid_from);

CREATE INDEX idx_guideline_values_standard
    ON eco.guideline_values (standard_id);

CREATE INDEX idx_results_sample
    ON eco.results (sample_id);

CREATE INDEX idx_results_param
    ON eco.results (param_id);

CREATE INDEX idx_results_qc
    ON eco.results (qc_code);

CREATE INDEX idx_result_exceedances_result
    ON eco.result_exceedances (result_id);

CREATE INDEX idx_result_exceedances_gv
    ON eco.result_exceedances (gv_id);

CREATE INDEX idx_result_exceedances_standard
    ON eco.result_exceedances (standard_id);

CREATE INDEX idx_field_measurements_point_time
    ON eco.field_measurements (point_id, measured_datetime);

CREATE INDEX idx_field_measurements_event
    ON eco.field_measurements (event_id);

CREATE INDEX idx_field_measurements_param
    ON eco.field_measurements (param_id);

CREATE INDEX idx_water_levels_point_time
    ON eco.water_levels (point_id, measured_datetime);

CREATE INDEX idx_attachments_entity
    ON eco.attachments (entity_type, entity_id);

CREATE INDEX idx_staging_batch_unprocessed
    ON eco.staging_lab_import (batch_code)
    WHERE processed_at IS NULL;

CREATE INDEX idx_staging_batch
    ON eco.staging_lab_import (batch_code, row_no);

INSERT INTO eco.schema_migrations (version, description)
VALUES ('003', 'Индексы GIST/btree и уникальный ключ проб')
ON CONFLICT (version) DO NOTHING;
