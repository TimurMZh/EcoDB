#!/usr/bin/env python3
"""
Download Oskemen (Ust-Kamenogorsk) air-quality readings into dataset/Oskemen/raw/.

KazHydroMet stations for this city live in the AirData.kz `rest_of_kz` dump
(there is no dedicated oskemen/ folder). Station names are generic ("PCP #1"),
so rows are kept by distance from the city centre rather than by name.

Unlike Almaty, there is no Almaty Air Initiative low-cost network here; the
backbone is government reference stations only. Meteorology is NOT fetched
here; it is pulled per selected station by build_oskemen_stations.py.

Usage:
    python dataset/fetch_oskemen_raw.py
    python dataset/fetch_oskemen_raw.py --parameters pm25 so2 no2 co --force
"""

from __future__ import annotations

import argparse
import csv
import gzip
import io
import math
from collections import defaultdict
from pathlib import Path

import requests

AIRDATAKZ_BASE = "https://raw.githubusercontent.com/qazybekb/AirDatakz-OpenData/HEAD"

# rest_of_kz uses national parameter codes (pm2_5, not pm25).
PARAM_FILES = {
    "pm25": "rest_of_kz/pm2_5.csv.gz",
    "pm10": "rest_of_kz/pm10.csv.gz",
    "so2": "rest_of_kz/so2.csv.gz",
    "no2": "rest_of_kz/no2.csv.gz",
    "no": "rest_of_kz/no.csv.gz",
    "co": "rest_of_kz/co.csv.gz",
    "h2s": "rest_of_kz/h2s.csv.gz",
    "o3": "rest_of_kz/o3.csv.gz",
    "pmtot": "rest_of_kz/pmtot.csv.gz",
}

# City centre of Oskemen / Ust-Kamenogorsk. 18 km covers the urban stations
# and drops Glubokoe (~27 km west), whose PCP numbers collide with Oskemen's.
OSKEMEN_LAT = 49.978
OSKEMEN_LON = 82.615
DEFAULT_RADIUS_KM = 18.0

TIMEOUT = 180
HEADERS = {"User-Agent": "EcoProject-Oskemen/1.0 (air-quality fetch)"}

OUT_FIELDS = [
    "datetime_utc",
    "station_id",
    "station_name",
    "source",
    "lat",
    "lon",
    "value_ugm3",
    "raw_value",
    "raw_unit",
]


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlmb = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def in_oskemen(lat: str, lon: str, radius_km: float) -> bool:
    try:
        la, lo = float(lat), float(lon)
    except (TypeError, ValueError):
        return False
    return haversine_km(OSKEMEN_LAT, OSKEMEN_LON, la, lo) <= radius_km


def download_filtered(
    url: str,
    out_path: Path,
    radius_km: float,
    force: bool = False,
) -> dict[str, dict]:
    """
    Stream a national gzip CSV and write only Oskemen rows.

    Returns per-station counts (empty if the file could not be fetched).
    """
    if out_path.exists() and out_path.stat().st_size > 0 and not force:
        print(f"  cached  {out_path.name} ({out_path.stat().st_size / 1e6:.2f} MB)")
        return _summarize_existing(out_path)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_suffix(out_path.suffix + ".part")
    stations: dict[str, dict] = defaultdict(lambda: {"n": 0, "name": "", "lat": "", "lon": ""})
    kept = 0
    scanned = 0

    try:
        with requests.get(url, stream=True, timeout=TIMEOUT, headers=HEADERS) as resp:
            resp.raise_for_status()
            resp.raw.decode_content = False
            with gzip.GzipFile(fileobj=resp.raw) as gz:
                text = io.TextIOWrapper(gz, encoding="utf-8", errors="replace", newline="")
                reader = csv.DictReader(text)
                with gzip.open(tmp_path, "wt", encoding="utf-8", newline="") as out_fh:
                    writer = csv.DictWriter(out_fh, fieldnames=OUT_FIELDS)
                    writer.writeheader()
                    for row in reader:
                        scanned += 1
                        if not in_oskemen(row.get("lat"), row.get("lon"), radius_km):
                            continue
                        sid = str(row.get("station_id") or "").strip()
                        if not sid:
                            continue
                        station_id = sid if sid.startswith("kgmt_") else f"kgmt_{sid}"
                        rec = {
                            "datetime_utc": row.get("datetime_utc") or "",
                            "station_id": station_id,
                            "station_name": row.get("station_name") or "",
                            "source": row.get("source") or "kgmt",
                            "lat": row.get("lat") or "",
                            "lon": row.get("lon") or "",
                            "value_ugm3": row.get("value_ugm3") or "",
                            "raw_value": row.get("raw_value") or "",
                            "raw_unit": row.get("raw_unit") or "",
                        }
                        writer.writerow(rec)
                        kept += 1
                        info = stations[station_id]
                        info["n"] += 1
                        info["name"] = rec["station_name"]
                        info["lat"] = rec["lat"]
                        info["lon"] = rec["lon"]
                        if scanned % 500_000 == 0:
                            print(f"    scanned {scanned:,} rows, kept {kept:,}")
    except requests.RequestException as exc:
        tmp_path.unlink(missing_ok=True)
        print(f"  FAILED  {out_path.name}: {exc}")
        return {}

    if kept == 0:
        tmp_path.unlink(missing_ok=True)
        print(f"  empty   {out_path.name} (no Oskemen rows in {scanned:,} national rows)")
        return {}

    tmp_path.replace(out_path)
    print(
        f"  ok      {out_path.name} ({out_path.stat().st_size / 1e6:.2f} MB)  "
        f"kept {kept:,}/{scanned:,} rows, {len(stations)} stations"
    )
    return dict(stations)


def _summarize_existing(path: Path) -> dict[str, dict]:
    stations: dict[str, dict] = defaultdict(lambda: {"n": 0, "name": "", "lat": "", "lon": ""})
    with gzip.open(path, "rt", encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            sid = row.get("station_id") or ""
            info = stations[sid]
            info["n"] += 1
            info["name"] = row.get("station_name") or info["name"]
            info["lat"] = row.get("lat") or info["lat"]
            info["lon"] = row.get("lon") or info["lon"]
    print(f"           {sum(s['n'] for s in stations.values()):,} Oskemen rows, {len(stations)} stations")
    return dict(stations)


def write_station_preview(stations: dict[str, dict], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=["station_id", "station_name", "lat", "lon", "n_readings"])
        writer.writeheader()
        for sid, info in sorted(stations.items(), key=lambda kv: -kv[1]["n"]):
            writer.writerow(
                {
                    "station_id": sid,
                    "station_name": info["name"],
                    "lat": info["lat"],
                    "lon": info["lon"],
                    "n_readings": info["n"],
                }
            )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base_dir",
        type=str,
        default=str(Path(__file__).resolve().parent / "Oskemen"),
        help="Dataset directory; filtered files land in <base_dir>/raw.",
    )
    parser.add_argument(
        "--parameters",
        type=str,
        nargs="+",
        default=["pm25"],
        choices=sorted(PARAM_FILES),
        help="AirData.kz parameters to pull. All of them are written into station files by the build step.",
    )
    parser.add_argument(
        "--radius_km",
        type=float,
        default=DEFAULT_RADIUS_KM,
        help="Keep stations within this radius of Oskemen city centre.",
    )
    parser.add_argument("--force", action="store_true", help="Re-download files already cached.")
    args = parser.parse_args()

    raw_dir = Path(args.base_dir).resolve() / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)

    print(f"Raw directory: {raw_dir}")
    print(f"Oskemen filter: {args.radius_km:.0f} km around {OSKEMEN_LAT}, {OSKEMEN_LON}\n")

    merged: dict[str, dict] = {}
    ok = 0
    for param in args.parameters:
        rel = PARAM_FILES[param]
        url = f"{AIRDATAKZ_BASE}/{rel}"
        out_name = f"airdatakz_oskemen_{param}.csv.gz"
        print(f"KazHydroMet {param} (AirData.kz rest_of_kz):")
        stations = download_filtered(url, raw_dir / out_name, args.radius_km, force=args.force)
        if stations:
            ok += 1
            for sid, info in stations.items():
                prev = merged.get(sid)
                if prev is None or info["n"] > prev["n"]:
                    merged[sid] = info

    if merged:
        preview = raw_dir / "stations_found.csv"
        write_station_preview(merged, preview)
        print(f"\nStation preview: {preview}")
        for sid, info in sorted(merged.items(), key=lambda kv: -kv[1]["n"]):
            print(f"  {sid:<16s} {info['name']:<12s} n={info['n']:7d}  {info['lat']}, {info['lon']}")

    print(f"\nDone. {ok}/{len(args.parameters)} parameter files with Oskemen data.")
    if ok == 0:
        print("Warning: no files written. Check the network or widen --radius_km.")
        raise SystemExit(1)
    if "pm25" not in args.parameters:
        print("Note: build_oskemen_stations.py selects stations using PM2.5.")


if __name__ == "__main__":
    main()
