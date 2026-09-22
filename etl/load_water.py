"""Load water report tables (Excel) and named wells (PDF) into staging.

These files are not laboratory dumps. Excel tables are wide (quarter columns)
with anonymous point numbers. The PDF table 9 names wells but has no coordinates
and no sample date. Blank quarter cells are omitted. «нет» is loaded and
rejected by fn_parse_lab_result as "not measured".
"""

from __future__ import annotations

import json
import re
import sys
from datetime import date
from pathlib import Path

import fitz
from openpyxl import load_workbook
from psycopg2.extras import Json, execute_values

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from db import connect  # noqa: E402

DB_INPUT = ROOT / "DB_input"
SURFACE_XLSX = DB_INPUT / "Результаты мониторинга поверхностных вод.xlsx"
GROUND_XLSX = DB_INPUT / "Результаты мониторинга подземных вод.xlsx"
WELLS_PDF = DB_INPUT / "Результаты мониторинга.pdf"

BATCH_SURFACE = "WATER_SURFACE_2025"
BATCH_GROUND = "WATER_GROUND_2025"
BATCH_WELLS = "WATER_WELLS_PDF"
LAB_CODE = "PEK"

QUARTER_RE = re.compile(r"(\d)\s*кв\s*(\d{4})", re.IGNORECASE)
QUARTER_MONTH = {1: 1, 2: 4, 3: 7, 4: 10}

# Longest first so «Железо общее» wins over a shorter prefix.
PDF_PARAM_NAMES = [
    "Взвешенные вещества",
    "Железо общее",
    "Жесткость общая",
    "Гидрокарбонаты",
    "Сухой остаток",
    "Сульфаты",
    "Цианиды",
    "Хлориды",
    "Кальций",
    "Мышьяк",
    "Магний",
    "рН",
]


def _cell_text(val) -> str | None:
    if val is None:
        return None
    if isinstance(val, float):
        if val == int(val) and abs(val) < 1e12:
            return str(int(val))
        return format(val, "g")
    text = str(val).strip()
    return text or None


def _quarter_date(year: int, quarter: int) -> date:
    return date(year, QUARTER_MONTH[quarter], 1)


def parse_report(path: Path, point_prefix: str) -> tuple[list[tuple], int]:
    """Unpivot a table-9 style workbook. Returns staging tuples and blank-cell count."""
    wb = load_workbook(path, data_only=True, read_only=True)
    ws = wb.active
    quarters: list[tuple[int, int, int]] = []
    header_seen = False
    point_no: int | None = None
    out: list[tuple] = []
    blank = 0

    for excel_row, row in enumerate(ws.iter_rows(values_only=True), start=1):
        cells = list(row)
        if not header_seen:
            blob = " ".join(str(c) for c in cells if c is not None).lower()
            if "наименование" not in blob:
                continue
            header_seen = True
            for col, cell in enumerate(cells):
                if cell is None:
                    continue
                match = QUARTER_RE.search(str(cell))
                if match:
                    quarters.append((col, int(match.group(1)), int(match.group(2))))
            if not quarters:
                raise RuntimeError(f"no quarter columns in {path.name}")
            continue

        if not any(c is not None for c in cells):
            continue
        head = cells[0]
        if isinstance(head, (int, float)) and float(head) == int(head):
            point_no = int(head)
        name = cells[1] if len(cells) > 1 else None
        if point_no is None or name is None or not str(name).strip():
            continue

        pdk = cells[2] if len(cells) > 2 else None
        for col, quarter, year in quarters:
            raw = cells[col] if col < len(cells) else None
            if raw is None or (isinstance(raw, str) and not raw.strip()):
                blank += 1
                continue
            out.append(
                (
                    point_prefix,
                    path.name,
                    ws.title,
                    excel_row * 10 + quarter,
                    f"{point_prefix}-{point_no}",
                    str(name).strip(),
                    _quarter_date(year, quarter),
                    _cell_text(raw),
                    _cell_text(pdk),
                    year,
                    quarter,
                    Json(
                        {
                            "report_point_no": point_no,
                            "source_pdk": _cell_text(pdk),
                            "source_pdk_ignored": True,
                        }
                    ),
                )
            )
    wb.close()
    if not header_seen:
        raise RuntimeError(f"header row not found in {path.name}")
    return out, blank


def _split_param_names(text: str) -> list[str]:
    rest = text.strip()
    found: list[str] = []
    while rest:
        hit = next((name for name in PDF_PARAM_NAMES if rest.lower().startswith(name.lower())), None)
        if hit is None:
            return [text.strip()] if not found else found + [rest]
        found.append(hit)
        rest = rest[len(hit) :].strip()
    return found


def _well_code(label: str) -> str:
    text = re.sub(r"(?i)скважина", " ", label)
    text = text.replace("№", " ")
    text = re.sub(r"\s+", " ", text).strip()
    return text


def parse_wells(path: Path) -> list[tuple]:
    """Table 9 of the monitoring PDF. Sample date is not in the file."""
    doc = fitz.open(path)
    out: list[tuple] = []
    pending: list[str] = []
    seq = 0
    assumed = date(2025, 1, 1)

    for page_index in (4, 5):
        table = doc[page_index].find_tables().tables[0]
        wide = page_index == 4
        for row in table.extract():
            cells = [(c or "").replace("\n", " ").strip() for c in row]
            point_label = cells[0]
            if "скважин" not in point_label.lower():
                continue
            param_cell = cells[1] if len(cells) > 1 else ""
            value = cells[5] if wide else cells[3]
            if not value:
                continue

            if param_cell:
                names = _split_param_names(param_cell)
                current = names[0]
                pending = names[1:]
            elif pending:
                current = pending.pop(0)
            else:
                continue

            seq += 1
            out.append(
                (
                    "WELLS",
                    path.name,
                    f"page-{page_index + 1}",
                    seq,
                    _well_code(point_label),
                    current,
                    assumed,
                    value.replace(" ", ""),
                    "Не норм-ся",
                    2025,
                    None,
                    Json(
                        {
                            "date_assumed": True,
                            "assumed_date": assumed.isoformat(),
                            "reason": "В PDF нет даты отбора; принят 2025-01-01 (год отчёта Excel).",
                            "pdf_point": point_label,
                            "source_pdk": "Не норм-ся",
                        }
                    ),
                )
            )
    doc.close()
    return out


def _staging_tuple(batch: str, media: str, row: tuple) -> tuple:
    prefix, source_file, sheet, row_no, point, param, coll, result, pdk, year, quarter, extra = row
    return (
        batch,
        source_file,
        sheet,
        row_no,
        LAB_CODE,
        point,
        media,
        param,
        coll,
        result,
        pdk,
        year,
        quarter,
        extra,
    )


def clear_water(cur) -> None:
    cur.execute(
        """
        DELETE FROM eco.results r
        USING eco.samples sm
            JOIN eco.sampling_events e ON e.event_id = sm.event_id
            JOIN eco.monitoring_points p ON p.point_id = e.point_id
        WHERE r.sample_id = sm.sample_id
          AND p.media_type IN ('surface_water', 'groundwater')
        """
    )
    cur.execute(
        """
        DELETE FROM eco.samples sm
        USING eco.sampling_events e
            JOIN eco.monitoring_points p ON p.point_id = e.point_id
        WHERE sm.event_id = e.event_id
          AND p.media_type IN ('surface_water', 'groundwater')
        """
    )
    cur.execute(
        """
        DELETE FROM eco.sampling_events e
        USING eco.monitoring_points p
        WHERE e.point_id = p.point_id
          AND p.media_type IN ('surface_water', 'groundwater')
        """
    )
    cur.execute(
        "DELETE FROM eco.staging_lab_import WHERE batch_code = ANY(%s)",
        ([BATCH_SURFACE, BATCH_GROUND, BATCH_WELLS],),
    )


def _process(cur, batch: str) -> dict:
    cur.execute("SELECT metric, value FROM eco.fn_process_staging_import(%s)", (batch,))
    metrics = dict(cur.fetchall())
    cur.execute(
        """
        SELECT COALESCE(process_error, '(ok)'), count(*)
        FROM eco.staging_lab_import
        WHERE batch_code = %s
        GROUP BY 1
        ORDER BY 2 DESC
        """,
        (batch,),
    )
    print(f"{batch}: {json.dumps(metrics, ensure_ascii=False)}")
    for msg, cnt in cur.fetchall():
        print(f"  {cnt:5d}  {msg}")
    return metrics


def load_water(*, reload: bool = True) -> None:
    surface, surface_blank = parse_report(SURFACE_XLSX, "SW")
    ground, ground_blank = parse_report(GROUND_XLSX, "GW")
    wells = parse_wells(WELLS_PDF)

    rows = [
        *[_staging_tuple(BATCH_SURFACE, "surface_water", row) for row in surface],
        *[_staging_tuple(BATCH_GROUND, "groundwater", row) for row in ground],
        *[_staging_tuple(BATCH_WELLS, "groundwater", row) for row in wells],
    ]

    conn = connect()
    try:
        cur = conn.cursor()
        if reload:
            clear_water(cur)
        execute_values(
            cur,
            """
            INSERT INTO eco.staging_lab_import (
                batch_code, source_file, source_sheet, row_no,
                lab_code, point_code, media_type, param_name_raw,
                collection_date, result_text, pdk_raw,
                year_num, quarter_num, extra_json
            ) VALUES %s
            """,
            rows,
            page_size=500,
        )
        conn.commit()

        print(f"surface rows {len(surface)} (blank quarters skipped {surface_blank})")
        print(f"ground rows {len(ground)} (blank quarters skipped {ground_blank})")
        print(f"pdf well rows {len(wells)}")
        _process(cur, BATCH_SURFACE)
        _process(cur, BATCH_GROUND)
        _process(cur, BATCH_WELLS)
        conn.commit()

        cur.execute(
            """
            SELECT e.media_type, count(*)
            FROM eco.results r
            JOIN eco.samples sm ON sm.sample_id = r.sample_id
            JOIN eco.sampling_events e ON e.event_id = sm.event_id
            WHERE e.media_type IN ('surface_water', 'groundwater')
            GROUP BY 1
            ORDER BY 1
            """
        )
        print("water results by media:", cur.fetchall())
        cur.execute(
            """
            SELECT p.point_code, pr.param_code, r.result_value, x.ratio
            FROM eco.result_exceedances x
            JOIN eco.results r ON r.result_id = x.result_id
            JOIN eco.parameters pr ON pr.param_id = r.param_id
            JOIN eco.samples sm ON sm.sample_id = r.sample_id
            JOIN eco.sampling_events e ON e.event_id = sm.event_id
            JOIN eco.monitoring_points p ON p.point_id = e.point_id
            WHERE e.media_type IN ('surface_water', 'groundwater')
            ORDER BY p.point_code, pr.param_code
            """
        )
        print("water exceedances:")
        for rec in cur.fetchall():
            print(" ", rec)
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    load_water(reload="--no-reload" not in sys.argv)
