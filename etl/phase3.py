#!/usr/bin/env python3
"""Phase 3: refresh dictionaries, then load surface water, groundwater, and PDF wells."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from load_water import load_water  # noqa: E402
from seed_dictionaries import seed  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description="EcoDB Phase 3: water loaders")
    parser.add_argument(
        "step",
        nargs="?",
        default="all",
        choices=("all", "seed", "water"),
        help="all (default), seed only, or water only",
    )
    parser.add_argument(
        "--no-reload",
        action="store_true",
        help="do not delete previous water batches before insert",
    )
    args = parser.parse_args()

    if args.step in ("all", "seed"):
        seed()
    if args.step in ("all", "water"):
        load_water(reload=not args.no_reload)


if __name__ == "__main__":
    main()
