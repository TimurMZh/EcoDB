#!/usr/bin/env python3
"""Phase 2: seed dictionaries, then load the air Excel pilot batch."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from load_air import load_air  # noqa: E402
from seed_dictionaries import seed  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description="EcoDB Phase 2: dictionaries + AIR_PILOT")
    parser.add_argument(
        "step",
        nargs="?",
        default="all",
        choices=("all", "seed", "air"),
        help="all (default), seed only, or air only",
    )
    parser.add_argument(
        "--no-reload",
        action="store_true",
        help="do not delete previous AIR_PILOT rows before insert",
    )
    parser.add_argument(
        "--no-impute-hcn",
        action="store_true",
        help="leave empty HCN cells empty (they will fail processing)",
    )
    args = parser.parse_args()

    if args.step in ("all", "seed"):
        seed()
    if args.step in ("all", "air"):
        load_air(reload=not args.no_reload, impute_hcn=not args.no_impute_hcn)


if __name__ == "__main__":
    main()
