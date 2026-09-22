#!/usr/bin/env python3
"""Plot Oskemen air-quality collection devices on an interactive map and PNG."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd

ROOT = Path(__file__).resolve().parent
DEFAULT_CSV = ROOT / "Oskemen" / "station.csv"
DEFAULT_HTML = ROOT / "Oskemen" / "stations_map.html"
DEFAULT_PNG = ROOT / "Oskemen" / "stations_map.png"

SOURCE_COLORS = {
    "kgmt": "#dc2626",
}
SOURCE_LABELS = {
    "kgmt": "KazHydroMet",
}


def load_stations(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    required = {"station", "longitude", "latitude", "source"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"station.csv missing columns: {sorted(missing)}")
    return df.dropna(subset=["longitude", "latitude"]).copy()


def write_html(df: pd.DataFrame, out_path: Path) -> None:
    points = []
    for row in df.itertuples(index=False):
        source = str(row.source)
        points.append(
            {
                "id": str(row.station),
                "lat": float(row.latitude),
                "lon": float(row.longitude),
                "alt": float(row.altitude) if hasattr(row, "altitude") and pd.notna(row.altitude) else None,
                "source": source,
                "label": SOURCE_LABELS.get(source, source),
                "color": SOURCE_COLORS.get(source, "#64748b"),
            }
        )

    center_lat = float(df["latitude"].mean())
    center_lon = float(df["longitude"].mean())
    legend = [
        {
            "source": s,
            "label": SOURCE_LABELS.get(s, s),
            "color": SOURCE_COLORS.get(s, "#64748b"),
            "n": int((df["source"] == s).sum()),
        }
        for s in sorted(df["source"].unique())
    ]

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Oskemen air-quality stations</title>
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
        integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY=" crossorigin="" />
  <style>
    html, body {{ margin: 0; height: 100%; font-family: system-ui, sans-serif; }}
    #map {{ height: 100%; width: 100%; }}
    .panel {{
      position: absolute; z-index: 1000; top: 12px; left: 12px;
      background: rgba(255,255,255,0.95); padding: 12px 14px; border-radius: 8px;
      box-shadow: 0 1px 4px rgba(0,0,0,0.2); max-width: 280px;
    }}
    .panel h1 {{ margin: 0 0 6px; font-size: 15px; }}
    .panel p {{ margin: 0 0 8px; font-size: 12px; color: #444; }}
    .legend-row {{ display: flex; align-items: center; gap: 8px; font-size: 12px; margin: 4px 0; }}
    .dot {{ width: 10px; height: 10px; border-radius: 50%; border: 1px solid #fff; box-shadow: 0 0 0 1px #333; }}
  </style>
</head>
<body>
  <div class="panel">
    <h1>Oskemen collection devices</h1>
    <p>{len(df)} stations · sources from station.csv</p>
    {''.join(f'<div class="legend-row"><span class="dot" style="background:{item["color"]}"></span>{item["label"]} ({item["n"]})</div>' for item in legend)}
  </div>
  <div id="map"></div>
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"
          integrity="sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo=" crossorigin=""></script>
  <script>
    const points = {json.dumps(points)};
    const map = L.map('map').setView([{center_lat}, {center_lon}], 12);
    L.tileLayer('https://{{s}}.tile.openstreetmap.org/{{z}}/{{x}}/{{y}}.png', {{
      maxZoom: 18,
      attribution: '&copy; OpenStreetMap'
    }}).addTo(map);

    const bounds = [];
    for (const p of points) {{
      const alt = p.alt == null ? 'n/a' : p.alt.toFixed(0) + ' m';
      const marker = L.circleMarker([p.lat, p.lon], {{
        radius: 7,
        color: '#111',
        weight: 1,
        fillColor: p.color,
        fillOpacity: 0.9
      }}).addTo(map);
      marker.bindPopup(
        '<b>' + p.id + '</b><br>' +
        p.label + '<br>' +
        p.lat.toFixed(5) + ', ' + p.lon.toFixed(5) + '<br>' +
        'altitude: ' + alt
      );
      bounds.push([p.lat, p.lon]);
    }}
    if (bounds.length) map.fitBounds(bounds, {{ padding: [40, 40] }});
  </script>
</body>
</html>
"""
    out_path.write_text(html, encoding="utf-8")


def write_png(df: pd.DataFrame, out_path: Path) -> None:
    fig, ax = plt.subplots(figsize=(9, 8), dpi=150)
    for source, group in df.groupby("source"):
        color = SOURCE_COLORS.get(source, "#64748b")
        label = f"{SOURCE_LABELS.get(source, source)} (n={len(group)})"
        ax.scatter(
            group["longitude"],
            group["latitude"],
            c=color,
            s=55,
            edgecolors="black",
            linewidths=0.4,
            label=label,
            zorder=3,
        )
        for row in group.itertuples(index=False):
            ax.annotate(
                row.station.replace("kgmt_", ""),
                (row.longitude, row.latitude),
                textcoords="offset points",
                xytext=(4, 3),
                fontsize=7,
                alpha=0.85,
            )

    ax.set_xlabel("Longitude")
    ax.set_ylabel("Latitude")
    ax.set_title(f"Oskemen air-quality stations ({len(df)} devices)")
    ax.grid(True, linestyle="--", alpha=0.35)
    ax.set_aspect("equal", adjustable="datalim")
    ax.legend(loc="best", fontsize=9)
    fig.tight_layout()
    fig.savefig(out_path)
    plt.close(fig)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV)
    parser.add_argument("--html", type=Path, default=DEFAULT_HTML)
    parser.add_argument("--png", type=Path, default=DEFAULT_PNG)
    args = parser.parse_args()

    if not args.csv.exists():
        raise FileNotFoundError(f"{args.csv} missing. Run dataset/build_oskemen_stations.py first.")

    df = load_stations(args.csv)
    args.html.parent.mkdir(parents=True, exist_ok=True)
    write_html(df, args.html)
    write_png(df, args.png)
    print(f"Wrote {args.html}")
    print(f"Wrote {args.png}")
    print(f"Stations: {len(df)}")
    print(df["source"].value_counts().to_string())


if __name__ == "__main__":
    main()
