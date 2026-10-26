"""Write reports/dashboard.html from the dash_* tables made by sql/80_dashboard.sql.

The tables are embedded in the page as JSON, exactly as DuckDB returns them, and
the page only filters and draws them. Nothing is computed here, so every figure
on the page can be traced to sql/80_dashboard.sql.
"""
import json
import sys
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

import duckdb

from . import config

TEMPLATE = Path(__file__).with_name("dashboard_template.html")
PLACEHOLDER = "/*__DASHBOARD_DATA__*/null"


def _json_value(v):
    if isinstance(v, (date, datetime)):
        return v.isoformat()
    if isinstance(v, Decimal):
        return float(v)
    raise TypeError(f"cannot embed {type(v).__name__} in the dashboard")


def tables(con: duckdb.DuckDBPyConnection) -> dict:
    names = [r[0] for r in con.execute(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_name LIKE 'dash\\_%' ESCAPE '\\' ORDER BY table_name").fetchall()]
    out = {}
    for name in names:
        cur = con.execute(f"SELECT * FROM {name}")
        out[name] = {"columns": [d[0] for d in cur.description], "rows": cur.fetchall()}
    return out


def render(con: duckdb.DuckDBPyConnection, root: Path) -> Path:
    data = json.dumps(tables(con), default=_json_value, ensure_ascii=False, separators=(",", ":"))
    # Keep the JSON from closing the <script> element it sits in.
    data = data.replace("</", "<\\/")
    page = TEMPLATE.read_text(encoding="utf-8")
    if page.count(PLACEHOLDER) != 1:
        raise ValueError(f"{TEMPLATE.name} must contain {PLACEHOLDER} exactly once")
    out = root / config.REPORTS_DIR / "dashboard.html"
    out.parent.mkdir(exist_ok=True)
    out.write_text(page.replace(PLACEHOLDER, data), encoding="utf-8")
    print(f"dashboard: {out.relative_to(root)} ({out.stat().st_size // 1024} KB)", file=sys.stderr)
    return out
