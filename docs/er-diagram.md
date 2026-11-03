# Диаграмма сущность–связь EcoDB

Физическая модель схемы `eco` (PostgreSQL / PostGIS). Источник: `sql/migrations/002_tables.sql` и `012_oskemen_stations.sql`.

Мощности связей следуют объявленным внешним ключам. У `staging_lab_import` и `attachments` внешних ключей нет: staging — сырой снимок, вложения полиморфны.

```mermaid
erDiagram
    sites ||--o{ monitoring_points : "имеет"
    ref_media_types ||--o{ monitoring_points : "среда"
    monitoring_points ||--o{ point_aliases : "синоним"

    sites ||--o{ sampling_events : "размещает"
    monitoring_points ||--o{ sampling_events : "на точке"
    ref_media_types ||--o{ sampling_events : "среда"

    sampling_events ||--o{ samples : "отбирает"
    laboratories |o--o{ samples : "анализирует"

    samples ||--o{ results : "имеет"
    parameters ||--o{ results : "измерен"
    ref_qc_codes |o--o{ results : "qc"

    results ||--o{ result_exceedances : "отмечено"
    guideline_values ||--o{ result_exceedances : "по нормативу"
    guideline_standards ||--o{ result_exceedances : "стандарт"

    parameters ||--o{ parameter_aliases : "синоним"
    parameters ||--o{ guideline_values : "предел для"
    guideline_standards ||--o{ guideline_values : "задаёт"
    ref_media_types ||--o{ guideline_values : "среда"
    ref_media_types |o--o{ parameters : "основная среда"
    ref_media_types |o--o{ guideline_standards : "среда"

    monitoring_points ||--o{ field_measurements : "на точке"
    sampling_events |o--o{ field_measurements : "во время"
    parameters ||--o{ field_measurements : "измерен"
    monitoring_points ||--o{ water_levels : "на точке"
    monitoring_points ||--o{ meteo_observations : "погода"

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
        bigint lab_id FK "может быть NULL"
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
        text media_type FK "может быть NULL"
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
        text media_type FK "может быть NULL"
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
        char qc_code FK "может быть NULL"
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
        bigint event_id FK "может быть NULL"
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

    meteo_observations {
        bigint meteo_id PK
        bigint point_id FK
        timestamptz observed_at
        numeric temperature
        numeric pressure
        numeric humidity
        numeric wind_speed
        numeric wind_direction
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
        text entity_type "полиморфная связь"
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

## Предметные области

| Область | Таблицы |
|---|---|
| Пространство | `sites`, `monitoring_points`, `point_aliases` |
| Отбор проб | `laboratories`, `sampling_events`, `samples` |
| Результаты | `results`, `result_exceedances`, `ref_qc_codes` |
| НСИ / ПДК | `parameters`, `parameter_aliases`, `guideline_standards`, `guideline_values` |
| Поле | `field_measurements`, `water_levels` |
| Датчики | `meteo_observations`; почасовые загрязнители лежат в `samples` (`sample_type = hourly_sensor`) и `results` |
| Прочее | `ref_media_types`, `attachments`, `staging_lab_import` |

## Примечания

- Уникальность `sampling_events`: `(point_id, event_date, media_type)`.
- Уникальность `results`: `(sample_id, param_id)` — повторный импорт обновляет строку.
- Уникальность `guideline_values`: `(standard_id, param_id, media_type, valid_from)`.
- `attachments.entity_type` — одно из: `site`, `monitoring_point`, `sampling_event`, `sample`, `result`, `laboratory`.
- Сначала загружается `staging_lab_import`, затем `fn_process_staging_import()` пишет в события, пробы и результаты.
- Почасовые значения Казгидромета — это `samples.sample_type = 'hourly_sensor'` (одна проба на станцию и час) и `results` в `ug/m3`. Пустые ячейки источника не хранятся. Лабораторные Query Layer этот тип пробы исключают.
- У `meteo_observations` нет внешнего ключа на `samples`. Соединение: `meteo.point_id = sampling_events.point_id` и `meteo.observed_at = samples.collection_datetime` (`vw_sensor_hourly`, `vw_sensor_latest`).
- Представления (`vw_results_flat`, `vw_exceedances_summary`, `vw_latest_results`, `vw_water_levels`, `vw_sensor_latest`, `vw_sensor_latest_wide`, `vw_sensor_daily`) сущностями не являются: это проекции Query Layer поверх этой модели.
