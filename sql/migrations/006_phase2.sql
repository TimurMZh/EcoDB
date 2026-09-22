-- 006_phase2.sql
-- Уникальность сырых строк партии (повторная загрузка AIR_PILOT).

CREATE UNIQUE INDEX IF NOT EXISTS uq_staging_batch_file_row
    ON eco.staging_lab_import (batch_code, source_file, row_no)
    WHERE source_file IS NOT NULL AND row_no IS NOT NULL;

INSERT INTO eco.schema_migrations (version, description)
VALUES ('006', 'Уникальный индекс staging (batch, file, row) для повторной загрузки')
ON CONFLICT (version) DO NOTHING;
