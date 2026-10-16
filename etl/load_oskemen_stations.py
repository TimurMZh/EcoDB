"""Load Oskemen KazHydroMet station CSVs into eco.results and eco.meteo_observations.

Hourly pollutant cells become results (sample_type = hourly_sensor, unit ug/m3).
Empty pollutant cells are skipped. Meteorology is a separate table keyed by
(point_id, observed_at) and joined in vw_sensor_hourly / vw_sensor_latest.

Usage:
    python3 etl/load_oskemen_stations.py
    python3 etl/load_oskemen_stations.py --since 2026-10-01
"""

from __future__ import annotations

import argparse
import csv
import sys
from datetime import datetime, timezone
from io import StringIO
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from db import connect  # noqa: E402

DEFAULT_DIR = ROOT / "dataset" / "Oskemen"

# CSV column -> eco.parameters.param_code (ug/m3). Lab SO2/NO2/CO stay mg/m3.
POLLUTANT_TO_CODE = {
    "PM2.5": "PM25",
    "PM10": "PM10",
    "PMtot": "PMtot",
    "SO2": "SO2_UG",
    "NO2": "NO2_UG",
    "NO": "NO",
    "CO": "CO_UG",
    "H2S": "H2S",
    "O3": "O3",
}

METEO_COLUMNS = ["temperature", "pressure", "humidity", "wind_speed", "wind_direction"]

SITE = {
    "site_code": "OSK",
    "name_ru": "Усть-Каменогорск (Оскемен)",
    "name_en": "Oskemen",
    "region": "Восточно-Казахстанская область",
}

SENSOR_PARAMS = [
    ("PM25", "PM2.5", "PM2.5", 11),
    ("PM10", "PM10", "PM10", 12),
    ("PMtot", "Взвешенные частицы (всего)", "Total particulate matter", 13),
    ("SO2_UG", "Сера диоксид (автостанция)", "Sulfur dioxide (station)", 14),
    ("NO2_UG", "Азота диоксид (автостанция)", "Nitrogen dioxide (station)", 15),
    ("NO", "Азота оксид", "Nitrogen monoxide", 16),
    ("CO_UG", "Углерода оксид (автостанция)", "Carbon monoxide (station)", 17),
    ("H2S", "Сероводород", "Hydrogen sulfide", 18),
    ("O3", "Озон", "Ozone", 19),
]


def _parse_utc(text: str) -> datetime:
    dt = datetime.fromisoformat(text.strip())
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _copy_csv(cur, table: str, columns: list[str], buf: StringIO) -> None:
    buf.seek(0)
    cur.copy_expert(
        f"COPY {table} ({', '.join(columns)}) FROM STDIN WITH (FORMAT csv, NULL '')",
        buf,
    )


def _upsert_catalog(cur, station_csv: Path) -> None:
    cur.execute(
        """
        INSERT INTO eco.sites (site_code, name_ru, name_en, region)
        VALUES (%(site_code)s, %(name_ru)s, %(name_en)s, %(region)s)
        ON CONFLICT (site_code) DO UPDATE
        SET name_ru = EXCLUDED.name_ru,
            name_en = EXCLUDED.name_en,
            region = EXCLUDED.region
        RETURNING site_id
        """,
        SITE,
    )
    site_id = cur.fetchone()[0]

    cur.execute(
        """
        INSERT INTO eco.laboratories (lab_code, name_ru, name_en)
        VALUES ('KGMT', 'Казгидромет', 'KazHydroMet')
        ON CONFLICT (lab_code) DO UPDATE
        SET name_ru = EXCLUDED.name_ru, name_en = EXCLUDED.name_en
        """
    )

    for code, name_ru, name_en, sort in SENSOR_PARAMS:
        cur.execute(
            """
            INSERT INTO eco.parameters (
                param_code, name_ru, name_en, unit, media_type, group_name, sort_order
            )
            VALUES (%s, %s, %s, 'ug/m3', 'air', 'kgmt', %s)
            ON CONFLICT (param_code) DO UPDATE
            SET name_ru = EXCLUDED.name_ru,
                name_en = EXCLUDED.name_en,
                unit = EXCLUDED.unit,
                group_name = EXCLUDED.group_name,
                sort_order = EXCLUDED.sort_order
            """,
            (code, name_ru, name_en, sort),
        )

    with station_csv.open(newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            code = row["station"].strip()
            lon = float(row["longitude"])
            lat = float(row["latitude"])
            alt = float(row["altitude"]) if row.get("altitude") not in (None, "") else None
            cur.execute(
                """
                INSERT INTO eco.monitoring_points (
                    point_code, site_id, name_ru, name_en, media_type, point_type,
                    geom, elevation_m, comments
                )
                VALUES (
                    %s, %s, %s, %s, 'air', 'автостанция',
                    ST_SetSRID(ST_MakePoint(%s, %s), 4326), %s,
                    'KazHydroMet / AirData.kz'
                )
                ON CONFLICT (point_code) DO UPDATE
                SET site_id = EXCLUDED.site_id,
                    name_ru = EXCLUDED.name_ru,
                    name_en = EXCLUDED.name_en,
                    media_type = EXCLUDED.media_type,
                    point_type = EXCLUDED.point_type,
                    geom = EXCLUDED.geom,
                    elevation_m = EXCLUDED.elevation_m,
                    comments = EXCLUDED.comments
                RETURNING point_id
                """,
                (
                    code,
                    site_id,
                    f"Казгидромет {code.replace('kgmt_', '')}",
                    f"KazHydroMet {code.replace('kgmt_', '')}",
                    lon,
                    lat,
                    alt,
                ),
            )
            point_id = cur.fetchone()[0]
            short = code.replace("kgmt_", "")
            for alias in (code, short):
                cur.execute(
                    """
                    INSERT INTO eco.point_aliases (point_id, alias_norm, source_system)
                    SELECT %s, eco.fn_norm_label(%s), 'kgmt'
                    WHERE NOT EXISTS (
                        SELECT 1 FROM eco.point_aliases
                        WHERE alias_norm = eco.fn_norm_label(%s)
                          AND COALESCE(source_system, '') = 'kgmt'
                    )
                    """,
                    (point_id, alias, alias),
                )


def _clear_window(cur, since: datetime | None) -> None:
    cur.execute(
        """
        DELETE FROM eco.results r
        USING eco.samples s
        WHERE r.sample_id = s.sample_id
          AND s.sample_type = 'hourly_sensor'
          AND (%s IS NULL OR s.collection_datetime >= %s)
        """,
        (since, since),
    )
    cur.execute(
        """
        DELETE FROM eco.samples
        WHERE sample_type = 'hourly_sensor'
          AND (%s IS NULL OR collection_datetime >= %s)
        """,
        (since, since),
    )
    cur.execute(
        """
        DELETE FROM eco.sampling_events e
        USING eco.monitoring_points p
        WHERE e.point_id = p.point_id
          AND p.point_type = 'автостанция'
          AND e.media_type = 'air'
          AND NOT EXISTS (
              SELECT 1 FROM eco.samples s WHERE s.event_id = e.event_id
          )
        """
    )
    cur.execute(
        """
        DELETE FROM eco.meteo_observations m
        USING eco.monitoring_points p
        WHERE m.point_id = p.point_id
          AND p.point_type = 'автостанция'
          AND (%s IS NULL OR m.observed_at >= %s)
        """,
        (since, since),
    )


def _read_station_file(
    path: Path, since: datetime | None
) -> tuple[StringIO, StringIO, int, int]:
    obs = StringIO()
    meteo = StringIO()
    obs_w = csv.writer(obs)
    meteo_w = csv.writer(meteo)
    n_obs = n_meteo = 0
    point_code = path.stem

    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        missing = [c for c in ("time", *METEO_COLUMNS) if c not in (reader.fieldnames or [])]
        if missing:
            raise ValueError(f"{path.name} missing columns: {missing}")
        pollutant_cols = [c for c in POLLUTANT_TO_CODE if c in (reader.fieldnames or [])]

        for row in reader:
            observed_at = _parse_utc(row["time"])
            if since is not None and observed_at < since:
                continue
            ts = observed_at.strftime("%Y-%m-%d %H:%M:%S+00")
            meteo_w.writerow(
                [
                    point_code,
                    ts,
                    row.get("temperature", "").strip(),
                    row.get("pressure", "").strip(),
                    row.get("humidity", "").strip(),
                    row.get("wind_speed", "").strip(),
                    row.get("wind_direction", "").strip(),
                ]
            )
            n_meteo += 1
            for col in pollutant_cols:
                raw = (row.get(col) or "").strip()
                if raw == "":
                    continue
                obs_w.writerow([point_code, ts, POLLUTANT_TO_CODE[col], raw])
                n_obs += 1

    return obs, meteo, n_obs, n_meteo


def _insert_from_temp(cur) -> dict[str, int]:
    cur.execute(
        """
        INSERT INTO eco.sampling_events (
            site_id, point_id, event_date, event_datetime, media_type, sampled_by, comments
        )
        SELECT
            p.site_id,
            p.point_id,
            (d.observed_at AT TIME ZONE 'UTC')::date,
            ((d.observed_at AT TIME ZONE 'UTC')::date)::timestamp AT TIME ZONE 'UTC',
            'air',
            'KazHydroMet',
            'Hourly KazHydroMet / AirData.kz'
        FROM (SELECT DISTINCT point_code, observed_at FROM tmp_kgmt_obs) d
        JOIN eco.monitoring_points p ON p.point_code = d.point_code
        ON CONFLICT (point_id, event_date, media_type) DO NOTHING
        """
    )
    n_events = cur.rowcount

    cur.execute(
        """
        INSERT INTO eco.samples (
            event_id, lab_id, sample_code, sample_type, collection_datetime, comments
        )
        SELECT
            e.event_id,
            lab.lab_id,
            p.point_code || ':' || to_char(
                h.observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'
            ),
            'hourly_sensor',
            h.observed_at,
            'AirData.kz published value, ug/m3'
        FROM (SELECT DISTINCT point_code, observed_at FROM tmp_kgmt_obs) h
        JOIN eco.monitoring_points p ON p.point_code = h.point_code
        JOIN eco.sampling_events e
            ON e.point_id = p.point_id
           AND e.event_date = (h.observed_at AT TIME ZONE 'UTC')::date
           AND e.media_type = 'air'
        JOIN eco.laboratories lab ON lab.lab_code = 'KGMT'
        """
    )
    n_samples = cur.rowcount

    cur.execute("ALTER TABLE eco.results DISABLE TRIGGER trg_check_exceedances")
    cur.execute(
        """
        INSERT INTO eco.results (
            sample_id, param_id, result_value, less_than, unit, qc_code, qc_reason, lab_method
        )
        SELECT
            s.sample_id,
            pr.param_id,
            o.result_value,
            false,
            'ug/m3',
            'C',
            'kgmt_published',
            'KazHydroMet automatic station'
        FROM tmp_kgmt_obs o
        JOIN eco.monitoring_points p ON p.point_code = o.point_code
        JOIN eco.samples s ON s.sample_code = p.point_code || ':' || to_char(
            o.observed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'
        )
        JOIN eco.parameters pr ON pr.param_code = o.param_code
        """
    )
    n_results = cur.rowcount
    cur.execute("ALTER TABLE eco.results ENABLE TRIGGER trg_check_exceedances")

    cur.execute(
        """
        INSERT INTO eco.meteo_observations (
            point_id, observed_at, temperature, pressure, humidity,
            wind_speed, wind_direction, source_system
        )
        SELECT
            p.point_id, m.observed_at, m.temperature, m.pressure, m.humidity,
            m.wind_speed, m.wind_direction, 'open-meteo-era5'
        FROM tmp_kgmt_meteo m
        JOIN eco.monitoring_points p ON p.point_code = m.point_code
        ON CONFLICT (point_id, observed_at) DO UPDATE
        SET temperature    = EXCLUDED.temperature,
            pressure       = EXCLUDED.pressure,
            humidity       = EXCLUDED.humidity,
            wind_speed     = EXCLUDED.wind_speed,
            wind_direction = EXCLUDED.wind_direction,
            source_system  = EXCLUDED.source_system
        """
    )
    n_meteo = cur.rowcount
    return {
        "events": n_events,
        "samples": n_samples,
        "results": n_results,
        "meteo": n_meteo,
    }


def load_oskemen_stations(
    base_dir: Path | None = None,
    *,
    since: datetime | None = None,
    reload: bool = True,
) -> None:
    base_dir = Path(base_dir) if base_dir else DEFAULT_DIR
    station_csv = base_dir / "station.csv"
    stations_dir = base_dir / "stations"
    if not station_csv.exists():
        raise FileNotFoundError(station_csv)
    files = sorted(stations_dir.glob("kgmt_*.csv"))
    if not files:
        raise FileNotFoundError(stations_dir / "kgmt_*.csv")

    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute("SET TIME ZONE 'UTC'")
        cur.execute("SET work_mem = '256MB'")
        _upsert_catalog(cur, station_csv)
        if reload:
            print("Clearing previous hourly_sensor / meteo window...")
            _clear_window(cur, since)

        cur.execute(
            """
            CREATE TEMP TABLE tmp_kgmt_obs (
                point_code      text            NOT NULL,
                observed_at     timestamptz     NOT NULL,
                param_code      text            NOT NULL,
                result_value    numeric         NOT NULL
            )
            """
        )
        cur.execute(
            """
            CREATE TEMP TABLE tmp_kgmt_meteo (
                point_code      text            NOT NULL,
                observed_at     timestamptz     NOT NULL,
                temperature     numeric,
                pressure        numeric,
                humidity        numeric,
                wind_speed      numeric,
                wind_direction  numeric
            )
            """
        )

        total_obs = total_meteo = 0
        for path in files:
            obs_buf, meteo_buf, n_obs, n_meteo = _read_station_file(path, since)
            _copy_csv(
                cur,
                "tmp_kgmt_obs",
                ["point_code", "observed_at", "param_code", "result_value"],
                obs_buf,
            )
            _copy_csv(
                cur,
                "tmp_kgmt_meteo",
                [
                    "point_code",
                    "observed_at",
                    "temperature",
                    "pressure",
                    "humidity",
                    "wind_speed",
                    "wind_direction",
                ],
                meteo_buf,
            )
            total_obs += n_obs
            total_meteo += n_meteo
            print(f"  {path.name}: {n_obs} pollutant values, {n_meteo} meteo hours")

        cur.execute("CREATE INDEX ON tmp_kgmt_obs (point_code, observed_at)")
        cur.execute("CREATE INDEX ON tmp_kgmt_meteo (point_code, observed_at)")
        print("Inserting events / samples / results / meteo...")
        counts = _insert_from_temp(cur)
        conn.commit()

        cur.execute(
            """
            SELECT count(*) FROM eco.results r
            JOIN eco.samples s ON s.sample_id = r.sample_id
            WHERE s.sample_type = 'hourly_sensor'
            """
        )
        n_stored = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM eco.meteo_observations")
        n_meteo_stored = cur.fetchone()[0]
        cur.execute(
            """
            SELECT count(*) FROM eco.monitoring_points
            WHERE point_type = 'автостанция' AND geom IS NOT NULL
            """
        )
        n_points = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM eco.vw_sensor_latest")
        n_latest = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM eco.vw_sensor_latest_wide")
        n_wide = cur.fetchone()[0]

        print(f"catalog points with geom: {n_points}")
        print(f"copied pollutant cells: {total_obs}; inserted results: {counts['results']}")
        print(f"copied meteo hours: {total_meteo}; upserted meteo: {counts['meteo']}")
        print(f"events +{counts['events']}, samples +{counts['samples']}")
        print(f"stored hourly results: {n_stored}; meteo rows: {n_meteo_stored}")
        cur.execute(
            "ANALYZE eco.sampling_events, eco.samples, eco.results, eco.meteo_observations, eco.monitoring_points"
        )
        print(f"vw_sensor_latest: {n_latest}; vw_sensor_latest_wide: {n_wide}")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base_dir",
        type=str,
        default=str(DEFAULT_DIR),
        help="Directory with station.csv and stations/*.csv",
    )
    parser.add_argument(
        "--since",
        type=str,
        default=None,
        help="Replace rows from this UTC timestamp onward (ISO). Default: full reload.",
    )
    args = parser.parse_args()
    since = _parse_utc(args.since) if args.since else None
    load_oskemen_stations(Path(args.base_dir), since=since, reload=True)


if __name__ == "__main__":
    main()
