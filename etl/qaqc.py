"""Phase 4 QA/QC: integrity checks, QC codes, 5% protocol sample, report.

Rules live in eco.qa_rules. A random 5% of results is drawn with a fixed seed.
The PDF is the only protocol in DB_input: every well row is re-read and compared,
and each air-protocol value is looked up in the loaded series.
"""

from __future__ import annotations

import math
import random
import re
import sys
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

import fitz

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from db import connect  # noqa: E402
from load_water import WELLS_PDF, parse_report, parse_wells  # noqa: E402

RULES_VERSION = "phase4-2026-09-22"
SAMPLE_SEED = 20260922
REPORT_PATH = ROOT / "docs" / "qa_phase4_report.md"
TOLERANCE = Decimal("0.0001")

AIR_PARAM_HINTS = (
    ("пыль", "Dust"),
    ("азота диоксид", "NO2"),
    ("сера диоксид", "SO2"),
    ("углерода оксид", "CO"),
    ("цианид", "HCN"),
    ("цианист", "HCN"),
)


def _norm_text(value: str) -> str:
    return " ".join(value.lower().replace("ё", "е").split())


def _parse_protocol_number(text: str | None) -> tuple[bool, Decimal | None]:
    if text is None or not str(text).strip():
        return False, None
    raw = str(text).strip().lower().replace("ё", "е")
    compact = re.sub(r"[\s.]", "", raw)
    if compact in {"необн", "необнаружено", "нд", "nd"}:
        return True, None
    token = raw.replace(" ", "").replace(",", ".")
    less = False
    if token.startswith("<=") or token[:1] in {"<", "≤", "⩽"}:
        less = True
        token = re.sub(r"^(<=|[<≤⩽])", "", token)
    if re.fullmatch(r"-?[0-9]+(\.[0-9]+)?([eE][-+]?\d+)?", token or ""):
        return less, Decimal(token)
    return False, None


def _values_match(loaded_value, loaded_less: bool, protocol_less: bool, protocol_value: Decimal | None) -> bool:
    if protocol_less and protocol_value is None:
        return loaded_less
    if loaded_value is None or protocol_value is None:
        return False
    if abs(Decimal(loaded_value) - protocol_value) > TOLERANCE:
        return False
    return loaded_less == protocol_less


def _air_point(label: str) -> str | None:
    match = re.search(r"(\d+)", label)
    if not match or "т" not in label.lower():
        return None
    return f"Т-{int(match.group(1))}"


def _protocol_value_cell(cells: list[str]) -> str | None:
    for cell in cells[3:]:
        if not cell:
            continue
        low = cell.lower()
        if "не обн" in low:
            return cell
        if "прев" in low or "треб" in low or "коорд" in low:
            continue
        compact = cell.replace(" ", "")
        if re.fullmatch(r"[0-9]+([.,][0-9]+)?", compact):
            return cell
    return None


def extract_air_protocol(path: Path) -> list[dict]:
    doc = fitz.open(path)
    rows: list[dict] = []
    current = None
    for page_index in range(min(4, doc.page_count)):
        found = doc[page_index].find_tables()
        if not found.tables:
            continue
        for raw in found.tables[0].extract():
            cells = [(c or "").replace("\n", " ").strip() for c in raw]
            point = _air_point(cells[0]) if cells and cells[0] else None
            if point:
                current = point
            param = cells[1] if len(cells) > 1 else ""
            if not current or not param or "наименование" in param.lower():
                continue
            value = _protocol_value_cell(cells)
            if not value:
                continue
            rows.append(
                {
                    "point_code": current,
                    "param_name": param,
                    "protocol_value": value,
                    "page": str(page_index + 1),
                }
            )
    doc.close()
    return rows


def _resolve_param(cur, name: str, media: str) -> tuple[int | None, str | None]:
    hinted = None
    if media == "air":
        hinted = next((code for needle, code in AIR_PARAM_HINTS if needle in _norm_text(name)), None)
    if hinted:
        cur.execute("SELECT param_id, param_code FROM eco.parameters WHERE param_code = %s", (hinted,))
        row = cur.fetchone()
        if row:
            return row[0], row[1]
    cur.execute(
        "SELECT p.param_id, p.param_code FROM eco.parameters p WHERE p.param_id = eco.fn_resolve_param_id(NULL, %s, 'PDF')",
        (name,),
    )
    row = cur.fetchone()
    return (row[0], row[1]) if row else (None, None)


def _insert_finding(cur, run_id: int, severity: str, check_code: str, message: str, batch: str | None = None, details=None):
    cur.execute(
        """
        INSERT INTO eco.qa_findings (qa_run_id, severity, check_code, batch_code, message, details)
        VALUES (%s, %s, %s, %s, %s, %s)
        """,
        (run_id, severity, check_code, batch, message, details),
    )


def _integrity(cur, run_id: int) -> None:
    cur.execute(
        """
        SELECT batch_code,
               count(*) AS staged,
               count(*) FILTER (WHERE processed_at IS NOT NULL) AS ok,
               count(*) FILTER (WHERE process_error IS NOT NULL) AS err
        FROM eco.staging_lab_import
        GROUP BY batch_code
        ORDER BY batch_code
        """
    )
    for batch, staged, ok, err in cur.fetchall():
        unexplained = staged - ok - err
        severity = "error" if unexplained else "info"
        _insert_finding(
            cur,
            run_id,
            severity,
            "batch_reconciliation",
            f"{batch}: в staging {staged}, принято {ok}, отклонено {err}, без статуса {unexplained}.",
            batch,
        )

    checks = [
        (
            "required_fields",
            """
            SELECT count(*) FROM eco.results r
            JOIN eco.samples sm ON sm.sample_id = r.sample_id
            JOIN eco.sampling_events e ON e.event_id = sm.event_id
            WHERE e.event_date IS NULL
               OR e.point_id IS NULL
               OR r.param_id IS NULL
               OR (r.result_value IS NULL AND NOT r.less_than)
            """,
            "Результаты без даты, точки, показателя или значения",
        ),
        (
            "duplicate_results",
            """
            SELECT count(*) FROM (
                SELECT sample_id, param_id FROM eco.results
                GROUP BY 1, 2 HAVING count(*) > 1
            ) d
            """,
            "Дубли (sample_id, param_id)",
        ),
        (
            "duplicate_exceedances",
            """
            SELECT count(*) FROM (
                SELECT result_id, gv_id FROM eco.result_exceedances
                GROUP BY 1, 2 HAVING count(*) > 1
            ) d
            """,
            "Дубли (result_id, gv_id)",
        ),
    ]
    for code, sql, title in checks:
        cur.execute(sql)
        n = cur.fetchone()[0]
        _insert_finding(
            cur,
            run_id,
            "error" if n else "info",
            code,
            f"{title}: {n}.",
        )

    cur.execute(
        """
        SELECT count(*) FROM eco.results r
        JOIN eco.parameters p ON p.param_id = r.param_id
        WHERE r.unit IS NOT NULL
          AND lower(replace(r.unit, ' ', '')) IS DISTINCT FROM lower(replace(p.unit, ' ', ''))
        """
    )
    n = cur.fetchone()[0]
    _insert_finding(
        cur,
        run_id,
        "warning" if n else "info",
        "unit_mismatch",
        f"Результатов с единицей, отличной от справочника: {n}.",
    )

    cur.execute("SELECT count(*) FROM eco.monitoring_points WHERE geom IS NULL")
    n = cur.fetchone()[0]
    _insert_finding(
        cur,
        run_id,
        "warning" if n else "info",
        "missing_geom",
        f"Точек без координат (geom NULL): {n}. Слой ArcGIS будет без геометрии, пока нет каталога точек.",
    )

    cur.execute(
        """
        SELECT count(*) FROM eco.results sw
        JOIN eco.samples sms ON sms.sample_id = sw.sample_id
        JOIN eco.sampling_events es ON es.event_id = sms.event_id
        JOIN eco.monitoring_points ps ON ps.point_id = es.point_id
        JOIN eco.monitoring_points pg
            ON pg.point_code = 'GW-' || substring(ps.point_code FROM 4)
        JOIN eco.sampling_events eg
            ON eg.point_id = pg.point_id AND eg.event_date = es.event_date
        JOIN eco.samples smg ON smg.event_id = eg.event_id
        JOIN eco.results gw
            ON gw.sample_id = smg.sample_id
           AND gw.param_id = sw.param_id
           AND gw.result_value IS NOT DISTINCT FROM sw.result_value
        WHERE ps.point_code LIKE 'SW-%'
        """
    )
    n = cur.fetchone()[0]
    _insert_finding(
        cur,
        run_id,
        "warning" if n else "info",
        "surface_ground_overlap",
        f"Пар SW/GW с тем же показателем, датой и значением: {n}. "
        "Файлы поверхностных и подземных вод за 1 кв. 2025 частично совпадают; точки не объединены.",
    )

    surface_rows, surface_blank = parse_report(ROOT / "DB_input" / "Результаты мониторинга поверхностных вод.xlsx", "SW")
    ground_rows, ground_blank = parse_report(ROOT / "DB_input" / "Результаты мониторинга подземных вод.xlsx", "GW")
    _insert_finding(
        cur,
        run_id,
        "info",
        "blank_quarters_skipped",
        f"Пустые кварталы не загружались: поверхностные {surface_blank} из отчёта ({len(surface_rows)} значений), "
        f"подземные {ground_blank} ({len(ground_rows)} непустых ячеек, включая «нет»).",
    )


def _protocol_rows(cur) -> list[dict]:
    air = extract_air_protocol(WELLS_PDF)
    for row in air:
        row["media"] = "air"
    wells = []
    for item in parse_wells(WELLS_PDF):
        _prefix, _file, sheet, _row_no, point, param, _date, value, _pdk, _year, _quarter, _extra = item
        wells.append(
            {
                "point_code": point,
                "param_name": param,
                "protocol_value": value,
                "page": sheet.replace("page-", ""),
                "media": "groundwater",
            }
        )
    return air + wells


def _loaded_for(cur, point_code: str, param_id: int) -> list[tuple]:
    cur.execute(
        """
        SELECT r.result_id, r.result_value, r.less_than, e.event_date
        FROM eco.results r
        JOIN eco.samples sm ON sm.sample_id = r.sample_id
        JOIN eco.sampling_events e ON e.event_id = sm.event_id
        JOIN eco.monitoring_points p ON p.point_id = e.point_id
        WHERE p.point_code = %s AND r.param_id = %s
        ORDER BY e.event_date, r.result_id
        """,
        (point_code, param_id),
    )
    return cur.fetchall()


def _spot_checks(cur, run_id: int) -> None:
    protocol = _protocol_rows(cur)
    for row in protocol:
        param_id, param_code = _resolve_param(cur, row["param_name"], row["media"])
        less, number = _parse_protocol_number(row["protocol_value"])
        if param_id is None:
            cur.execute(
                """
                INSERT INTO eco.qa_spot_checks (
                    qa_run_id, sample_kind, protocol_file, protocol_page,
                    protocol_value, disposition, notes
                ) VALUES (%s, 'protocol', %s, %s, %s, 'unmapped', %s)
                """,
                (run_id, WELLS_PDF.name, row["page"], row["protocol_value"], row["param_name"]),
            )
            continue
        loaded = _loaded_for(cur, row["point_code"], param_id)
        matches = [item for item in loaded if _values_match(item[1], item[2], less, number)]
        if row["media"] == "air" and less and number is None:
            # «не обн.» в PDF без даты нельзя привязать ко всем датам ряда.
            matches = []
        if matches:
            for result_id, value, loaded_less, event_date in matches:
                delta = None if value is None or number is None else Decimal(value) - number
                cur.execute(
                    """
                    INSERT INTO eco.qa_spot_checks (
                        qa_run_id, result_id, sample_kind, protocol_file, protocol_page,
                        protocol_value, loaded_value, loaded_less_than, delta, disposition, notes
                    ) VALUES (%s, %s, 'protocol', %s, %s, %s, %s, %s, %s, 'match', %s)
                    """,
                    (
                        run_id, result_id, WELLS_PDF.name, row["page"], row["protocol_value"],
                        value, loaded_less, delta,
                        f"{row['point_code']} {param_code} {event_date}",
                    ),
                )
        elif loaded and row["media"] == "groundwater":
            result_id, value, loaded_less, event_date = loaded[0]
            delta = None if value is None or number is None else Decimal(value) - number
            cur.execute(
                """
                INSERT INTO eco.qa_spot_checks (
                    qa_run_id, result_id, sample_kind, protocol_file, protocol_page,
                    protocol_value, loaded_value, loaded_less_than, delta, disposition, notes
                ) VALUES (%s, %s, 'protocol', %s, %s, %s, %s, %s, %s, 'mismatch', %s)
                """,
                (
                    run_id, result_id, WELLS_PDF.name, row["page"], row["protocol_value"],
                    value, loaded_less, delta,
                    f"{row['point_code']} {param_code} {event_date}",
                ),
            )
        else:
            note = f"{row['point_code']} / {row['param_name']}"
            if row["media"] == "air" and less and number is None:
                note += " — «не обн.» без даты отбора, к ряду Excel не привязано"
            cur.execute(
                """
                INSERT INTO eco.qa_spot_checks (
                    qa_run_id, sample_kind, protocol_file, protocol_page,
                    protocol_value, disposition, notes
                ) VALUES (%s, 'protocol', %s, %s, %s, 'not_in_db', %s)
                """,
                (run_id, WELLS_PDF.name, row["page"], row["protocol_value"], note),
            )

    cur.execute("SELECT result_id FROM eco.results ORDER BY result_id")
    ids = [row[0] for row in cur.fetchall()]
    sample_n = max(1, math.ceil(0.05 * len(ids)))
    chosen = random.Random(SAMPLE_SEED).sample(ids, sample_n)
    cur.execute(
        """
        SELECT result_id FROM eco.qa_spot_checks
        WHERE qa_run_id = %s AND disposition = 'match' AND result_id IS NOT NULL
        """,
        (run_id,),
    )
    matched = {row[0] for row in cur.fetchall()}
    for result_id in chosen:
        if result_id in matched:
            disposition = "match"
            notes = "попал в 5% и совпал с протоколом"
        else:
            disposition = "no_protocol"
            notes = "в комплекте DB_input нет протокола на эту дату и точку"
        cur.execute(
            """
            INSERT INTO eco.qa_spot_checks (
                qa_run_id, result_id, sample_kind, protocol_file, disposition, notes
            ) VALUES (%s, %s, 'random_5pct', %s, %s, %s)
            """,
            (run_id, result_id, WELLS_PDF.name, disposition, notes),
        )


def _markdown_table(headers: list[str], rows: list[tuple]) -> str:
    head = "| " + " | ".join(headers) + " |"
    sep = "| " + " | ".join("---" for _ in headers) + " |"
    body = ["| " + " | ".join("" if c is None else str(c) for c in row) + " |" for row in rows]
    return "\n".join([head, sep, *body])


def _write_report(cur, run_id: int) -> None:
    cur.execute(
        "SELECT started_at, finished_at FROM eco.qa_runs WHERE qa_run_id = %s",
        (run_id,),
    )
    started, finished = cur.fetchone()
    cur.execute(
        """
        SELECT qc_code, qc_reason, count(*)
        FROM eco.results
        GROUP BY 1, 2
        ORDER BY 1, 2
        """
    )
    codes = cur.fetchall()
    cur.execute(
        """
        SELECT severity, check_code, COALESCE(batch_code, ''), message
        FROM eco.qa_findings
        WHERE qa_run_id = %s
        ORDER BY CASE severity WHEN 'error' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, check_code
        """,
        (run_id,),
    )
    findings = cur.fetchall()
    cur.execute(
        """
        SELECT sample_kind, disposition, count(*)
        FROM eco.qa_spot_checks
        WHERE qa_run_id = %s
        GROUP BY 1, 2
        ORDER BY 1, 2
        """,
        (run_id,),
    )
    spots = cur.fetchall()
    cur.execute("SELECT count(*) FROM eco.results")
    n_results = cur.fetchone()[0]
    cur.execute(
        """
        SELECT extract(year FROM e.event_date)::int AS year, e.media_type, count(*)
        FROM eco.results r
        JOIN eco.samples sm ON sm.sample_id = r.sample_id
        JOIN eco.sampling_events e ON e.event_id = sm.event_id
        GROUP BY 1, 2
        ORDER BY 1, 2
        """
    )
    by_year = cur.fetchall()
    cur.execute(
        """
        SELECT COALESCE(l.lab_code, '—'), pr.param_code, count(*)
        FROM eco.results r
        JOIN eco.parameters pr ON pr.param_id = r.param_id
        JOIN eco.samples sm ON sm.sample_id = r.sample_id
        LEFT JOIN eco.laboratories l ON l.lab_id = sm.lab_id
        GROUP BY 1, 2
        ORDER BY 1, 2
        """
    )
    by_param = cur.fetchall()
    cur.execute(
        """
        SELECT si.site_code, count(*)
        FROM eco.result_exceedances x
        JOIN eco.results r ON r.result_id = x.result_id
        JOIN eco.samples sm ON sm.sample_id = r.sample_id
        JOIN eco.sampling_events e ON e.event_id = sm.event_id
        JOIN eco.sites si ON si.site_id = e.site_id
        GROUP BY 1
        """
    )
    exceed = cur.fetchall()
    cur.execute(
        """
        SELECT p.point_code, pr.param_code, sc.protocol_value, sc.loaded_value, sc.delta, sc.disposition
        FROM eco.qa_spot_checks sc
        LEFT JOIN eco.results r ON r.result_id = sc.result_id
        LEFT JOIN eco.parameters pr ON pr.param_id = r.param_id
        LEFT JOIN eco.samples sm ON sm.sample_id = r.sample_id
        LEFT JOIN eco.sampling_events e ON e.event_id = sm.event_id
        LEFT JOIN eco.monitoring_points p ON p.point_id = e.point_id
        WHERE sc.qa_run_id = %s AND sc.sample_kind = 'protocol' AND sc.disposition = 'mismatch'
        ORDER BY 1, 2
        """,
        (run_id,),
    )
    mismatches = cur.fetchall()

    lines = [
        "# Отчёт QA/QC — фаза 4",
        "",
        f"Прогон `{run_id}`, правила `{RULES_VERSION}`.",
        f"Начало: {started}. Окончание: {finished}.",
        "",
        "## Объём",
        "",
        f"Результатов в БД: **{n_results}**.",
        "",
        "### По году и среде",
        "",
        _markdown_table(["Год", "Среда", "Результатов"], by_year),
        "",
        "### По лаборатории и показателю",
        "",
        _markdown_table(["Лаборатория", "Показатель", "Результатов"], by_param),
        "",
        "### Превышения ПДК",
        "",
        _markdown_table(["Объект", "Превышений"], exceed) if exceed else "Превышений нет.",
        "",
        "## Коды QC",
        "",
        "Приоритет: расхождение с протоколом (R), совпадение с протоколом (A), "
        "пустая ячейка заменена на «не обн.» (R), чужая единица (R), выброс > 10×ПДК (R), "
        "ниже МДО по источнику (B), иначе C. Коды D и R не попадают в `vw_latest_results`.",
        "",
        _markdown_table(["Код", "Правило", "Записей"], codes),
        "",
        "## Контрольные проверки",
        "",
        _markdown_table(["Уровень", "Проверка", "Партия", "Сообщение"], findings),
        "",
        "## Акт выборочной сверки",
        "",
        f"Случайная выборка: 5% результатов, seed `{SAMPLE_SEED}`. "
        "Протокол в комплекте — только `Результаты мониторинга.pdf`. "
        "Скважины сверены полностью (повторное чтение PDF). "
        "Строки воздуха из PDF сопоставлены с рядом Excel по точке и показателю; "
        "«не обн.» без даты к ряду не привязывается.",
        "",
        _markdown_table(["Выборка", "Итог", "Строк"], spots),
        "",
    ]
    if mismatches:
        lines.extend(
            [
                "### Расхождения с протоколом",
                "",
                _markdown_table(
                    ["Точка", "Показатель", "В протоколе", "В БД", "Дельта", "Итог"],
                    mismatches,
                ),
                "",
            ]
        )
    else:
        lines.extend(["Расхождений «загружено ≠ протокол» по скважинам нет.", ""])
    lines.extend(
        [
            "## Как закрыты отклонения загрузки",
            "",
            "- Пустые ячейки воздуха (кроме HCN) остались в staging с ошибкой «Пустое значение результата» и в `results` не попали.",
            "- Пустой HCN в Excel записан как «не обн.» и получил код R (импутация), пока лаборатория не подтвердит МДО.",
            "- «нет» в подземных водах отклонено как «значение не измерено».",
            "- Пустые кварталы отчётов в staging не клались.",
            "- ПДК из колонки Excel (включая 0 и опечатки 2021-03-19) не использовались; пределы берутся из `guideline_values`.",
            "- Координаты точек отсутствуют — замечание `missing_geom`, на код QC результата не влияет.",
            "",
        ]
    )
    REPORT_PATH.write_text("\n".join(lines), encoding="utf-8")


def run() -> int:
    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO eco.qa_runs (rules_version, notes) VALUES (%s, %s) RETURNING qa_run_id",
            (RULES_VERSION, "Phase 4 QA/QC"),
        )
        run_id = cur.fetchone()[0]
        _integrity(cur, run_id)
        _spot_checks(cur, run_id)
        cur.execute("SELECT qc_code, n FROM eco.fn_apply_qc(%s)", (run_id,))
        summary = cur.fetchall()
        cur.execute(
            "UPDATE eco.qa_runs SET finished_at = %s WHERE qa_run_id = %s",
            (datetime.now(timezone.utc), run_id),
        )
        conn.commit()
        _write_report(cur, run_id)
        print(f"QA run {run_id}")
        for code, n in summary:
            print(f"  {code}: {n}")
        cur.execute(
            """
            SELECT severity, count(*) FROM eco.qa_findings
            WHERE qa_run_id = %s GROUP BY 1 ORDER BY 1
            """,
            (run_id,),
        )
        print("findings:", cur.fetchall())
        cur.execute(
            """
            SELECT sample_kind, disposition, count(*)
            FROM eco.qa_spot_checks WHERE qa_run_id = %s
            GROUP BY 1, 2 ORDER BY 1, 2
            """,
            (run_id,),
        )
        print("spot checks:")
        for row in cur.fetchall():
            print(" ", row)
        print(f"report: {REPORT_PATH}")
        return run_id
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    run()
