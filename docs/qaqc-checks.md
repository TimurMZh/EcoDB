# QA/QC checks

Checklist used by `python3 etl/phase4.py` (rules version `phase4-2026-09-22`).

Each run inserts one row in `eco.qa_runs`, writes findings to `eco.qa_findings`, writes the protocol sample to `eco.qa_spot_checks`, then sets `eco.results.qc_code` and `eco.results.qc_reason` through `eco.fn_apply_qc`. The numeric outcome of a run is `docs/qa_phase4_report.md`. This file is the list of checks, not that outcome.

```bash
./sql/apply.sh
python3 etl/phase4.py
psql -h localhost -U eco -d eco_monitoring -v ON_ERROR_STOP=1 -f sql/verify_phase4.sql
```

`sql/verify_phase4.sql` fails the latest finished run when any finding has severity `error`, any result has no QC code, the random sample is under 5% of results, a protocol row has disposition `mismatch`, or an imputed HCN result is not coded `R`.

## Severity

| Severity | Meaning |
|---|---|
| `error` | Integrity failure. The verify script rejects the run. |
| `warning` | Loaded data is usable, but a known gap remains. |
| `info` | Check completed and the count is explained. |

## 1. Integrity checks

Stored in `eco.qa_findings`. Implemented in `etl/qaqc.py` (`_integrity`).

| Code | Severity when it fails | What is checked |
|---|---|---|
| `batch_reconciliation` | `error` if any staging row is neither accepted nor rejected; otherwise `info` | For each `batch_code` in `eco.staging_lab_import`: staged = accepted (`processed_at` set) + rejected (`process_error` set). Nothing is left without a status. |
| `required_fields` | `error` if the count is not zero | Every result has a sampling date, a monitoring point, a parameter, and either `result_value` or `less_than`. |
| `duplicate_results` | `error` if the count is not zero | No duplicate pair `(sample_id, param_id)` in `eco.results`. |
| `duplicate_exceedances` | `error` if the count is not zero | No duplicate pair `(result_id, gv_id)` in `eco.result_exceedances`. |
| `unit_mismatch` | `warning` if the count is not zero | `results.unit` equals `parameters.unit` after lowercasing and removing spaces. A mismatch also sets QC code `R` (see below). |
| `missing_geom` | `warning` if any point has no geometry | Count of `eco.monitoring_points` with `geom IS NULL`. Does not change the result QC code. ArcGIS layers have no coordinates until a point catalogue arrives. |
| `surface_ground_overlap` | `warning` if the count is not zero | Pairs `SW-n` / `GW-n` with the same parameter, the same sampling date, and the same value. Points stay separate. Does not change the QC code. |
| `blank_quarters_skipped` | always `info` | Empty quarter cells in the surface and groundwater Excel reports. They are not inserted into staging. The finding records how many were skipped. |

Rejected staging rows (empty air values, groundwater «нет») are counted in `batch_reconciliation` and do not become results, so they receive no QC code.

## 2. QC code rules

Stored in `eco.qa_rules`. Applied to every row in `eco.results` by `eco.fn_apply_qc`. The first matching rule wins.

Codes `D` and `R` are excluded from `eco.vw_latest_results`. Code `D` (rejected) is defined in `eco.ref_qc_codes` but this runner does not assign it. Rows that fail parsing stay in staging.

| Priority | Rule | Code | When it applies |
|---|---|---|---|
| 1 | `protocol_mismatch` | R | This run's spot check says the PDF value and the loaded value differ. |
| 2 | `protocol_match` | A | This run's spot check says the loaded value matches the PDF. |
| 3 | `imputed_nondetect` | R | Staging `extra_json.imputed_nondetect` is true: a blank Excel cell was stored as «не обн.». Used for HCN in `AIR_PILOT`. |
| 4 | `unit_mismatch` | R | Result unit differs from `parameters.unit`. |
| 5 | `outlier_10x` | R | Not a non-detect, an active `GT`/`GTE` guideline applies on that date and medium, and `result_value` is greater than 10 × the limit. |
| 6 | `below_mdl` | B | `less_than` is true and no rule above matched. The source itself reported `<`, `≤`, or «не обн.». |
| 7 | `default_accept` | C | Numeric result with none of the rules above. |

`qc_reason` stores the winning rule code.

## 3. Protocol spot check

Stored in `eco.qa_spot_checks`. The only protocol file in `DB_input` is `Результаты мониторинга.pdf`. Numeric comparison tolerance is `0.0001`.

### Protocol pass (`sample_kind = protocol`)

Every air row on PDF pages 1–4 and every well row in table 9 (pages 5–6) is read again.

| Disposition | Meaning |
|---|---|
| `match` | Same point and parameter, and the loaded value agrees. Air «не обн.» with no number is not matched to the Excel series, because the PDF has no sample date. |
| `mismatch` | A groundwater well row exists in the database but the value differs. Sets QC code `R`. |
| `not_in_db` | The protocol line has no loaded counterpart. Includes air «не обн.» without a date, and PDF cells that glue two parameter names into one. |
| `unmapped` | The protocol parameter name does not resolve to `eco.parameters`. |

Air names are hinted only for medium `air` (dust, NO2, SO2, CO, HCN). Well names go through `eco.fn_resolve_param_id`, so «Цианиды» stays cyanide in water and is not treated as HCN.

### Random 5% (`sample_kind = random_5pct`)

`ceil(5% × number of results)` result ids, drawn with seed `20260922`.

| Disposition | Meaning |
|---|---|
| `match` | The drawn result was already matched to the PDF in the protocol pass. |
| `no_protocol` | `DB_input` has no protocol for that point and date. The QC code is left to the rules in section 2. |

## Where this is implemented

| Piece | Location |
|---|---|
| Tables, rule list, `fn_apply_qc` | `sql/migrations/009_qaqc.sql` |
| Findings, PDF compare, 5% sample, report | `etl/qaqc.py` |
| Entry point | `etl/phase4.py` |
| Acceptance check | `sql/verify_phase4.sql` |
| Latest run numbers | `docs/qa_phase4_report.md` |
