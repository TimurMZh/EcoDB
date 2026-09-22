# EcoDB entity-relationship diagram

Physical model of schema `eco` (PostgreSQL / PostGIS). Source: `sql/migrations/002_tables.sql`.

Cardinalities follow declared foreign keys. `staging_lab_import` and `attachments` have no FKs (staging is a raw snapshot; attachments are polymorphic).

```mermaid
erDiagram
    sites ||--o{ monitoring_points : "has"
    ref_media_types ||--o{ monitoring_points : "media"
    monitoring_points ||--o{ point_aliases : "aka"

    sites ||--o{ sampling_events : "hosts"
    monitoring_points ||--o{ sampling_events : "at"
    ref_media_types ||--o{ sampling_events : "media"

    sampling_events ||--o{ samples : "collects"
    laboratories |o--o{ samples : "analyzes"

    samples ||--o{ results : "has"
    parameters ||--o{ results : "measured"
    ref_qc_codes |o--o{ results : "qc"

    results ||--o{ result_exceedances : "flagged"
    guideline_values ||--o{ result_exceedances : "against"
    guideline_standards ||--o{ result_exceedances : "standard"

    parameters ||--o{ parameter_aliases : "aka"
    parameters ||--o{ guideline_values : "limit for"
    guideline_standards ||--o{ guideline_values : "defines"
    ref_media_types ||--o{ guideline_values : "media"
    ref_media_types |o--o{ parameters : "primary media"
    ref_media_types |o--o{ guideline_standards : "media"

    monitoring_points ||--o{ field_measurements : "at"
    sampling_events |o--o{ field_measurements : "during"
    parameters ||--o{ field_measurements : "measured"
    monitoring_points ||--o{ water_levels : "at"

    sites {
        bigint site_id PK
        text site_code UK
        text name_ru
        text region
        boolean is_active
    }

    monitoring_points {
        bigint point_id PK
        text point_code UK
        bigint site_id FK
        text media_type FK
        geometry geom "Point 4326"
        numeric elevation_m
        boolean is_active
    }

    point_aliases {
        bigint alias_id PK
        bigint point_id FK
        text alias_norm
        text source_system
    }

    laboratories {
        bigint lab_id PK
        text lab_code UK
        text name_ru
        text accreditation_no
        boolean is_active
    }

    sampling_events {
        bigint event_id PK
        bigint site_id FK
        bigint point_id FK
        date event_date
        text media_type FK
        text sampled_by
    }

    samples {
        bigint sample_id PK
        bigint event_id FK
        bigint lab_id FK "nullable"
        text sample_code
        text sample_type
        timestamptz collection_datetime
        text coc_number
    }

    parameters {
        bigint param_id PK
        text param_code UK
        text name_ru
        text unit
        text media_type FK "nullable"
        numeric mdl_default
    }

    parameter_aliases {
        bigint alias_id PK
        bigint param_id FK
        text alias_norm
        text source_system
    }

    guideline_standards {
        bigint standard_id PK
        text standard_code UK
        text name_ru
        text authority
        text media_type FK "nullable"
    }

    guideline_values {
        bigint gv_id PK
        bigint standard_id FK
        bigint param_id FK
        text media_type FK
        text comparison_op
        numeric limit_value
        date valid_from
        date valid_to
    }

    results {
        bigint result_id PK
        bigint sample_id FK
        bigint param_id FK
        numeric result_value
        boolean less_than
        numeric mdl
        char qc_code FK "nullable"
    }

    result_exceedances {
        bigint exceedance_id PK
        bigint result_id FK
        bigint gv_id FK
        bigint standard_id FK
        numeric limit_value_applied
        numeric ratio
        numeric exceedance_pct
    }

    field_measurements {
        bigint measurement_id PK
        bigint point_id FK
        bigint event_id FK "nullable"
        bigint param_id FK
        timestamptz measured_datetime
        numeric result_value
        text instrument
    }

    water_levels {
        bigint level_id PK
        bigint point_id FK
        timestamptz measured_datetime
        numeric depth_to_water_m
        numeric water_elevation_m
    }

    ref_media_types {
        text media_code PK
        text name_ru
        text name_en
        int sort_order
    }

    ref_qc_codes {
        char qc_code PK
        text name_ru
        boolean include_in_latest
    }

    attachments {
        bigint attachment_id PK
        text entity_type "polymorphic"
        bigint entity_id
        text file_name
        text file_uri
    }

    staging_lab_import {
        bigint staging_id PK
        text batch_code
        text lab_code
        text point_code
        text param_name_raw
        date collection_date
        text result_text
        timestamptz processed_at
        text process_error
    }
```

## Subject areas

| Area | Tables |
|---|---|
| Spatial | `sites`, `monitoring_points`, `point_aliases` |
| Sampling | `laboratories`, `sampling_events`, `samples` |
| Results | `results`, `result_exceedances`, `ref_qc_codes` |
| NSI / PDK | `parameters`, `parameter_aliases`, `guideline_standards`, `guideline_values` |
| Field | `field_measurements`, `water_levels` |
| Other | `ref_media_types`, `attachments`, `staging_lab_import` |

## Notes

- Unique on `sampling_events`: `(point_id, event_date, media_type)`.
- Unique on `results`: `(sample_id, param_id)` — re-import updates the row.
- Unique on `guideline_values`: `(standard_id, param_id, media_type, valid_from)`.
- `attachments.entity_type` is one of: `site`, `monitoring_point`, `sampling_event`, `sample`, `result`, `laboratory`.
- `staging_lab_import` is loaded first, then `fn_process_staging_import()` writes into events / samples / results.
- Views (`vw_results_flat`, `vw_exceedances_summary`, `vw_latest_results`, `vw_water_levels`) are not entities; they are Query Layer projections over this model.
