#!/usr/bin/env python3
"""Phase 4: run QA/QC checks, assign QC codes, write the spot-check report."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from qaqc import run  # noqa: E402


if __name__ == "__main__":
    run()
