"""PostgreSQL connection for EcoDB ETL (env: PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE)."""

from __future__ import annotations

import os

import psycopg2


def connect():
    return psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=os.environ.get("PGPORT", "5432"),
        user=os.environ.get("PGUSER", "eco"),
        password=os.environ.get("PGPASSWORD", "eco"),
        dbname=os.environ.get("PGDATABASE", "eco_monitoring"),
        client_encoding="UTF8",
    )
