#!/usr/bin/env python3
"""
Build dataset/Oskemen/ in the same station-panel layout as Almaty / Beijing1718,
from the raw files fetched by fetch_oskemen_raw.py.

This stops at the dataset. It does not build a graph or train a model.

Output:
    dataset/Oskemen/station.csv                 station,longitude,latitude,altitude,source
    dataset/Oskemen/stations/<station>.csv      time, pollutants, temperature, pressure,
                                               humidity, wind_speed, wind_direction
    dataset/Oskemen/observed_mask.npz           which pollutant cells are measured vs imputed
    dataset/Oskemen/build_report.json           station selection and imputation accounting

Stations are selected on PM2.5 coverage. Every other pollutant file present in
raw/ (pm10, so2, no2, …) is aligned to the same hourly grid, imputed, and written
as extra columns. Meteorology comes from the Open-Meteo ERA5 archive.

Usage:
    python dataset/fetch_oskemen_raw.py --parameters pm25 pm10 so2 no2 no co h2s o3 pmtot
    python dataset/build_oskemen_stations.py
"""

from __future__ import annotations

import argparse
import json
import time as time_mod
from pathlib import Path

import numpy as np
import pandas as pd
import requests

# Fetch code -> column in the station CSVs. Order here is the write order.
PARAM_COLUMNS = {
    "pm25": "PM2.5",
    "pm10": "PM10",
    "pmtot": "PMtot",
    "so2": "SO2",
    "no2": "NO2",
    "no": "NO",
    "co": "CO",
    "h2s": "H2S",
    "o3": "O3",
}

# Artifact caps (µg/m³). AirData.kz already QC'd; these only drop leftover spikes.
PARAM_MAX = {
    "pm25": 1000.0,
    "pm10": 2000.0,
    "pmtot": 3000.0,
    "so2": 5000.0,
    "no2": 2000.0,
    "no": 2000.0,
    "co": 50000.0,
    "h2s": 1000.0,
    "o3": 1000.0,
}

METEO_COLUMNS = ["temperature", "pressure", "humidity", "wind_speed", "wind_direction"]

METEO_VARS = {
    "temperature_2m": "temperature",
    "surface_pressure": "pressure",
    "relative_humidity_2m": "humidity",
    "wind_speed_10m": "wind_speed",
    "wind_direction_10m": "wind_direction",
}

OPEN_METEO_URL = "https://archive-api.open-meteo.com/v1/archive"


def discover_parameters(raw_dir: Path, requested: list[str] | None = None) -> list[str]:
    """Return fetch codes that have a raw file, in PARAM_COLUMNS order."""
    codes = list(PARAM_COLUMNS) if not requested else requested
    found = []
    for code in codes:
        if code not in PARAM_COLUMNS:
            raise SystemExit(f"Unknown parameter {code!r}. Choose from: {', '.join(PARAM_COLUMNS)}")
        path = raw_dir / f"airdatakz_oskemen_{code}.csv.gz"
        if path.exists():
            found.append(code)
        elif requested:
            raise FileNotFoundError(f"{path} missing. Re-run fetch_oskemen_raw.py with --parameters {code}.")
    return found


def last_timestamp(raw_dir: Path, code: str = "pm25") -> pd.Timestamp:
    """Last UTC-naive hour present in a fetched pollutant file."""
    path = raw_dir / f"airdatakz_oskemen_{code}.csv.gz"
    df = pd.read_csv(path, usecols=["datetime_utc"])
    t = pd.to_datetime(df["datetime_utc"], utc=True, errors="coerce").dt.tz_localize(None)
    return t.max().floor("h")


def load_parameter(raw_dir: Path, code: str, start: pd.Timestamp, end: pd.Timestamp) -> pd.DataFrame:
    """
    One pollutant from fetch_oskemen_raw.py.

    The column is named `datetime_utc` but carries -07:00/-08:00 offsets, so the
    wall clock is not UTC. Parsing as UTC-aware recovers the true instant.
    """
    path = raw_dir / f"airdatakz_oskemen_{code}.csv.gz"
    df = pd.read_csv(
        path,
        usecols=["datetime_utc", "station_id", "station_name", "source", "lat", "lon", "value_ugm3"],
    )
    df["time"] = pd.to_datetime(df["datetime_utc"], utc=True, errors="coerce").dt.tz_localize(None)
    df = df.rename(columns={"station_id": "station", "value_ugm3": "value"})
    df["station"] = df["station"].astype(str)
    df["source"] = df["source"].fillna("kgmt").astype(str)
    df.loc[df["source"].isin(["", "nan"]), "source"] = "kgmt"
    df = df.dropna(subset=["time", "value", "lat", "lon"])
    df = df[(df["time"] >= start) & (df["time"] <= end)]
    return df[["station", "time", "value", "lat", "lon", "source"]]


def build_panel(long_df: pd.DataFrame, grid: pd.DatetimeIndex, value_max: float) -> pd.DataFrame:
    """Collapse the long table to an hourly station-by-time matrix on `grid`."""
    if long_df.empty:
        return pd.DataFrame(index=grid)
    df = long_df.copy()
    df = df[(df["value"] >= 0) & (df["value"] <= value_max)]
    if df.empty:
        return pd.DataFrame(index=grid)
    df["time"] = df["time"].dt.floor("h")
    panel = df.pivot_table(index="time", columns="station", values="value", aggfunc="median")
    return panel.reindex(grid)


def station_metadata(long_df: pd.DataFrame) -> pd.DataFrame:
    """One row per station with its median reported coordinate and source."""
    meta = (
        long_df.groupby("station")
        .agg(latitude=("lat", "median"), longitude=("lon", "median"), source=("source", "first"))
        .reset_index()
    )
    return meta


def select_stations(
    panel: pd.DataFrame,
    meta: pd.DataFrame,
    min_coverage: float,
    max_stations: int,
    dedup_decimals: int,
) -> tuple[list[str], pd.DataFrame]:
    """Keep well-observed, spatially distinct stations, best-covered first."""
    coverage = panel.notna().mean().sort_values(ascending=False)
    meta = meta.set_index("station")

    kept: list[str] = []
    seen_coords: set[tuple[float, float]] = set()
    rows = []
    for station, cov in coverage.items():
        if station not in meta.index:
            continue
        lat = round(float(meta.loc[station, "latitude"]), dedup_decimals)
        lon = round(float(meta.loc[station, "longitude"]), dedup_decimals)
        reason = None
        if cov < min_coverage:
            reason = "below min_coverage"
        elif (lat, lon) in seen_coords:
            reason = "duplicate coordinate"
        elif len(kept) >= max_stations:
            reason = "max_stations reached"

        rows.append(
            {
                "station": station,
                "coverage": round(float(cov), 4),
                "source": meta.loc[station, "source"],
                "kept": reason is None,
                "reason": reason,
            }
        )
        if reason is None:
            kept.append(station)
            seen_coords.add((lat, lon))

    return kept, pd.DataFrame(rows)


def impute_panel(panel: pd.DataFrame, short_gap: int) -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    """
    Fill every cell, escalating from local to spatial to climatological
    evidence, and report how much of the panel each stage accounts for.
    """
    observed = panel.notna()
    total = int(observed.size)
    filled = panel.copy()

    filled = filled.interpolate(method="time", limit=short_gap, limit_area="inside")
    after_interp = filled.notna()

    city = panel.median(axis=1)
    city = city.interpolate(method="time", limit=24, limit_area="inside")

    ratios = {}
    for station in panel.columns:
        ratio = (panel[station] / city).replace([np.inf, -np.inf], np.nan).median()
        ratios[station] = float(ratio) if np.isfinite(ratio) and ratio > 0 else 1.0

    for station in panel.columns:
        need = filled[station].isna() & city.notna()
        filled.loc[need, station] = city[need] * ratios[station]
    after_spatial = filled.notna()

    month = panel.index.month
    hour = panel.index.hour
    global_median = float(np.nanmedian(panel.values))
    city_clim = pd.Series(panel.median(axis=1).values, index=panel.index).groupby([month, hour]).median()

    for station in panel.columns:
        need = filled[station].isna()
        if not need.any():
            continue
        clim = panel[station].groupby([month, hour]).median()
        keys = list(zip(month[need], hour[need]))
        values = [
            clim.get(key, np.nan) if np.isfinite(clim.get(key, np.nan)) else city_clim.get(key, np.nan)
            for key in keys
        ]
        values = [v if np.isfinite(v) else global_median for v in values]
        filled.loc[need, station] = values

    filled = filled.clip(lower=0.0)

    report = {
        "cells_total": total,
        "cells_measured": int(observed.values.sum()),
        "cells_filled_by_interpolation": int(after_interp.values.sum() - observed.values.sum()),
        "cells_filled_by_spatial": int(after_spatial.values.sum() - after_interp.values.sum()),
        "cells_filled_by_climatology": int(total - after_spatial.values.sum()),
        "measured_fraction": round(float(observed.values.mean()), 4),
        "station_ratio_to_city_median": {k: round(v, 4) for k, v in ratios.items()},
    }
    if filled.isna().to_numpy().any():
        raise RuntimeError("Imputation left NaN values; the panel cannot be consumed as-is.")
    return filled, observed, report


def fetch_meteo(
    stations: pd.DataFrame,
    grid: pd.DatetimeIndex,
    cache_dir: Path,
    batch_size: int,
    pause: float,
) -> tuple[dict[str, pd.DataFrame], dict[str, float]]:
    """Pull ERA5 reanalysis at each station coordinate from the Open-Meteo archive."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    start = grid[0].strftime("%Y-%m-%d")
    end = grid[-1].strftime("%Y-%m-%d")

    elevations = fetch_elevations(stations, cache_dir)

    frames: dict[str, pd.DataFrame] = {}
    pending = []
    for row in stations.itertuples(index=False):
        cache_path = cache_dir / f"{row.station}.csv"
        if cache_path.exists():
            cached = pd.read_csv(cache_path, parse_dates=["time"]).set_index("time")
            aligned = cached.reindex(grid)
            if not aligned.isna().to_numpy().any():
                frames[row.station] = aligned
                continue
        pending.append(row)

    if not pending:
        print(f"  all {len(frames)} stations already cached")
        return frames, elevations
    print(f"  {len(frames)} cached, {len(pending)} to fetch")

    batches = [pending[i : i + batch_size] for i in range(0, len(pending), batch_size)]
    for n, batch in enumerate(batches, start=1):
        params = {
            "latitude": ",".join(f"{r.latitude:.5f}" for r in batch),
            "longitude": ",".join(f"{r.longitude:.5f}" for r in batch),
            "start_date": start,
            "end_date": end,
            "hourly": ",".join(METEO_VARS),
            "timezone": "UTC",
            "wind_speed_unit": "kmh",
        }
        payload = _request_with_backoff(params, f"batch {n}/{len(batches)} ({len(batch)} stations)")
        if isinstance(payload, dict):
            payload = [payload]

        for row, loc in zip(batch, payload):
            hourly = loc["hourly"]
            met = pd.DataFrame({"time": pd.to_datetime(hourly["time"])})
            for api_name, out_name in METEO_VARS.items():
                met[out_name] = hourly[api_name]
            met = met.set_index("time").reindex(grid)
            met = met.interpolate(method="time", limit_direction="both")
            met.index.name = "time"
            met.to_csv(cache_dir / f"{row.station}.csv")
            frames[row.station] = met

        if pause and n < len(batches):
            time_mod.sleep(pause)

    return frames, elevations


def fetch_elevations(stations: pd.DataFrame, cache_dir: Path) -> dict[str, float]:
    """Resolve node altitude from the Open-Meteo elevation endpoint."""
    cache_path = cache_dir / "elevation.json"
    cached: dict[str, float] = {}
    if cache_path.exists():
        cached = {k: float(v) for k, v in json.loads(cache_path.read_text()).items()}

    missing = [r for r in stations.itertuples(index=False) if r.station not in cached]
    if missing:
        resp = requests.get(
            "https://api.open-meteo.com/v1/elevation",
            params={
                "latitude": ",".join(f"{r.latitude:.5f}" for r in missing),
                "longitude": ",".join(f"{r.longitude:.5f}" for r in missing),
            },
            timeout=120,
        )
        resp.raise_for_status()
        values = resp.json()["elevation"]
        cached.update({r.station: float(v) for r, v in zip(missing, values)})
        cache_dir.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps(cached, indent=2))
        print(f"  elevations: fetched {len(missing)}, total {len(cached)}")
    else:
        print(f"  elevations: all {len(cached)} cached")
    return cached


def _request_with_backoff(params: dict, label: str, max_attempts: int = 6):
    """GET the archive endpoint, backing off on rate limits."""
    delay = 20.0
    for attempt in range(1, max_attempts + 1):
        resp = requests.get(OPEN_METEO_URL, params=params, timeout=300)
        if resp.status_code == 200:
            print(f"  Open-Meteo {label}: ok")
            return resp.json()
        if resp.status_code == 429 or resp.status_code >= 500:
            if attempt == max_attempts:
                break
            print(
                f"  Open-Meteo {label}: HTTP {resp.status_code}, "
                f"retrying in {delay:.0f}s (attempt {attempt}/{max_attempts})"
            )
            time_mod.sleep(delay)
            delay = min(delay * 2, 300.0)
            continue
        resp.raise_for_status()
    raise RuntimeError(
        f"Open-Meteo {label} still failing after {max_attempts} attempts. "
        f"The daily quota may be exhausted; rerun later -- completed stations are cached."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base_dir", type=str, default=str(Path(__file__).resolve().parent / "Oskemen"))
    parser.add_argument("--start", type=str, default="2023-01-01")
    parser.add_argument(
        "--end",
        type=str,
        default=None,
        help="Last hour (UTC). Default: last timestamp in the fetched PM2.5 file.",
    )
    parser.add_argument(
        "--min_coverage",
        type=float,
        default=0.50,
        help="Minimum fraction of hours a station must actually measure.",
    )
    parser.add_argument("--max_stations", type=int, default=20)
    parser.add_argument("--min_stations", type=int, default=4)
    parser.add_argument("--short_gap", type=int, default=6, help="Hours of gap still filled by time interpolation.")
    parser.add_argument(
        "--parameters",
        type=str,
        nargs="*",
        default=None,
        help="Pollutants to include. Default: every airdatakz_oskemen_*.csv.gz in raw/.",
    )
    parser.add_argument("--pm25_max", type=float, default=1000.0, help="PM2.5 readings above this are treated as artifacts.")
    parser.add_argument("--dedup_decimals", type=int, default=3)
    parser.add_argument("--meteo_batch", type=int, default=5)
    parser.add_argument("--meteo_pause", type=float, default=1.0)
    args = parser.parse_args()

    base_dir = Path(args.base_dir).resolve()
    raw_dir = base_dir / "raw"
    start = pd.Timestamp(args.start)
    end = pd.Timestamp(args.end) if args.end else last_timestamp(raw_dir)
    if end < start:
        raise SystemExit(f"Empty window: start {start} is after end {end}.")
    grid = pd.date_range(start, end, freq="h")

    print(f"Target window: {grid[0]} .. {grid[-1]} ({len(grid)} hours, UTC)\n")

    param_codes = discover_parameters(raw_dir, args.parameters)
    if not param_codes:
        raise FileNotFoundError(
            f"No airdatakz_oskemen_*.csv.gz files in {raw_dir}. Run dataset/fetch_oskemen_raw.py first."
        )
    if "pm25" not in param_codes:
        raise FileNotFoundError(
            f"{raw_dir / 'airdatakz_oskemen_pm25.csv.gz'} missing. "
            "Station selection uses PM2.5; fetch that parameter first."
        )
    print(f"Pollutants: {', '.join(PARAM_COLUMNS[c] for c in param_codes)}")

    pm25 = load_parameter(raw_dir, "pm25", start, end)
    print(f"KazHydroMet PM2.5: {len(pm25):>8d} readings, {pm25.station.nunique():3d} stations")

    panel = build_panel(pm25, grid, args.pm25_max)
    meta = station_metadata(pm25)
    print(f"PM2.5 panel: {panel.shape[0]} hours x {panel.shape[1]} stations\n")

    kept, selection = select_stations(panel, meta, args.min_coverage, args.max_stations, args.dedup_decimals)
    print(f"Selected {len(kept)} stations at PM2.5 coverage >= {args.min_coverage:.0%}:")
    for row in selection[selection.kept].itertuples(index=False):
        print(f"  {row.station:<20s} {row.source:<12s} coverage={row.coverage:.3f}")
    if len(kept) < args.min_stations:
        raise SystemExit(
            f"Only {len(kept)} stations clear --min_coverage {args.min_coverage}. "
            f"Lower the threshold or narrow the window."
        )

    stations = meta[meta.station.isin(kept)].copy()
    stations["_order"] = stations["station"].map({s: i for i, s in enumerate(kept)})
    stations = stations.sort_values("_order").drop(columns="_order").reset_index(drop=True)

    filled_by_param: dict[str, pd.DataFrame] = {}
    observed_by_param: dict[str, pd.DataFrame] = {}
    impute_reports: dict[str, dict] = {}
    used_codes: list[str] = []

    print("\nFilling pollutant gaps...")
    for code in param_codes:
        col = PARAM_COLUMNS[code]
        if code == "pm25":
            long_df = pm25
            value_max = args.pm25_max
        else:
            long_df = load_parameter(raw_dir, code, start, end)
            value_max = PARAM_MAX[code]
        param_panel = build_panel(long_df, grid, value_max)
        for station in kept:
            if station not in param_panel.columns:
                param_panel[station] = np.nan
        param_panel = param_panel[kept]
        n_meas = int(param_panel.notna().to_numpy().sum())
        print(
            f"  {col:<6s} {len(long_df):>8d} readings, "
            f"{long_df.station.nunique():3d} stations, {n_meas} cells in window"
        )
        if n_meas == 0:
            print(f"    skip {col}: no readings in the target window")
            continue
        filled, observed, impute_report = impute_panel(param_panel, args.short_gap)
        print(
            f"    measured {impute_report['measured_fraction']:.1%} | "
            f"interpolated {impute_report['cells_filled_by_interpolation']} | "
            f"spatial {impute_report['cells_filled_by_spatial']} | "
            f"climatology {impute_report['cells_filled_by_climatology']}"
        )
        filled_by_param[col] = filled
        observed_by_param[col] = observed
        impute_reports[col] = impute_report
        used_codes.append(code)

    pollutant_cols = [PARAM_COLUMNS[c] for c in used_codes]
    output_columns = ["time", *pollutant_cols, *METEO_COLUMNS]

    print("\nFetching meteorology from the Open-Meteo ERA5 archive...")
    meteo, elevations = fetch_meteo(stations, grid, raw_dir / "meteo", args.meteo_batch, args.meteo_pause)
    stations["altitude"] = stations["station"].map(elevations).astype(float)

    stations_dir = base_dir / "stations"
    stations_dir.mkdir(parents=True, exist_ok=True)
    for stale in stations_dir.glob("*.csv"):
        stale.unlink()

    print(f"\nWriting {len(kept)} station files...")
    for station in kept:
        met = meteo[station].reindex(grid)
        out = pd.DataFrame({"time": grid})
        for col in pollutant_cols:
            out[col] = np.round(filled_by_param[col][station].reindex(grid).to_numpy(), 3)
        for col in METEO_COLUMNS:
            out[col] = met[col].to_numpy()
        out = out[output_columns]
        if out.isna().to_numpy().any():
            raise RuntimeError(f"{station}: NaN survived assembly.")
        out["time"] = out["time"].dt.strftime("%Y-%m-%d %H:%M:%S")
        out.to_csv(stations_dir / f"{station}.csv", index=False)

    station_csv = stations[["station", "longitude", "latitude", "altitude", "source"]]
    station_csv.to_csv(base_dir / "station.csv", index=False)

    mask_payload = {
        "stations": np.array(kept, dtype=object),
        "time": np.array(grid.strftime("%Y-%m-%d %H:%M:%S"), dtype=object),
        "parameters": np.array(pollutant_cols, dtype=object),
        "mask": observed_by_param[pollutant_cols[0]][kept].to_numpy(),
    }
    for col in pollutant_cols:
        mask_payload[f"mask_{col}"] = observed_by_param[col][kept].to_numpy()
    np.savez_compressed(base_dir / "observed_mask.npz", **mask_payload)

    report = {
        "city": "Oskemen",
        "window": {"start": str(grid[0]), "end": str(grid[-1]), "hours": len(grid), "timezone": "UTC"},
        "sources": ["kgmt"],
        "parameters": pollutant_cols,
        "stations_selected": len(kept),
        "stations": station_csv.to_dict(orient="records"),
        "selection": selection.to_dict(orient="records"),
        "imputation": impute_reports,
        "settings": {
            "min_coverage": args.min_coverage,
            "max_stations": args.max_stations,
            "short_gap_hours": args.short_gap,
            "pm25_max": args.pm25_max,
        },
    }
    (base_dir / "build_report.json").write_text(json.dumps(report, indent=2, default=str))

    print("\nDone.")
    print(f"  {base_dir / 'station.csv'}")
    print(f"  {stations_dir}/*.csv  ({len(kept)} files x {len(grid)} rows)")
    print(f"  {base_dir / 'observed_mask.npz'}")
    print(f"  {base_dir / 'build_report.json'}")
    print("\nOptional map:")
    print("  python dataset/plot_oskemen_stations.py")


if __name__ == "__main__":
    main()
