"""Rebuild build/monitor.duckdb from data/clean/ and run every .sql file.

Order: sql/00_load.sql, sql/checks/*.sql (by name), sql/90_summary.sql.
A file sql/checks/NN_<name>.sql must create table <name>; it is exported to
reports/<name>.csv.
"""
import csv
import subprocess
import sys
from pathlib import Path

import duckdb

from . import config

PREV_TABLES = ["comtrade", "gacc"]


def snapshot_prev(root: Path) -> dict:
    """Write data/clean/*.parquet as of git HEAD to build/prev/ (empty if absent)."""
    prev = root / config.BUILD_DIR / "prev"
    prev.mkdir(parents=True, exist_ok=True)
    commit = None
    try:
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True,
                                text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    found = {}
    for t in PREV_TABLES:
        out = prev / f"{t}.parquet"
        out.unlink(missing_ok=True)
        blob = None
        if commit:
            r = subprocess.run(["git", "show", f"HEAD:{config.CLEAN_DIR}/{t}.parquet"], cwd=root,
                               capture_output=True)
            blob = r.stdout if r.returncode == 0 else None
        if blob:
            out.write_bytes(blob)
            found[t] = True
        else:
            cur = (root / config.CLEAN_DIR / f"{t}.parquet").as_posix()
            duckdb.sql(f"COPY (SELECT * FROM read_parquet('{cur}') LIMIT 0) TO '{out.as_posix()}' (FORMAT parquet)")
            found[t] = False
    has = any(found.values())
    with (prev / "snapshot_meta.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["has_snapshot", "commit"])
        w.writerow(["true" if has else "false", commit if has else ""])
    return {"commit": commit if has else None, "tables": found}


def sql_files(root: Path) -> list[Path]:
    sql = root / config.SQL_DIR
    return [sql / "00_load.sql", *sorted((sql / "checks").glob("*.sql")), sql / "90_summary.sql"]


def check_table(path: Path) -> str | None:
    if path.parent.name != "checks":
        return None
    return path.stem.split("_", 1)[1]


def build(root: Path) -> duckdb.DuckDBPyConnection:
    db = root / config.DB_FILE
    db.parent.mkdir(parents=True, exist_ok=True)
    for p in (db, db.with_suffix(".duckdb.wal")):
        p.unlink(missing_ok=True)
    con = duckdb.connect(str(db))
    con.execute(f"SET file_search_path = '{root.as_posix()}'")
    reports = root / config.REPORTS_DIR
    reports.mkdir(exist_ok=True)
    for path in sql_files(root):
        con.execute(path.read_text())
        table = check_table(path) or ("run_summary" if path.stem == "90_summary" else None)
        if table:
            n = con.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            con.execute(f"COPY {table} TO '{(reports / f'{table}.csv').as_posix()}' (HEADER)")
            print(f"sql: {path.relative_to(root)} -> {table} ({n} rows)", file=sys.stderr)
    return con
