"""Fetch Bank Negara Malaysia's daily USD/MYR rates and save every response body unchanged.

One call per calendar month from START_MONTH to this month. Bodies are written
byte-for-byte to data/raw/<fetch-date>/bnm/; request metadata goes to a sidecar
manifest.jsonl in the same directory, as for Comtrade. The API needs no key.
"""
import hashlib
import json
import sys
import time
from datetime import date, datetime, timezone
from pathlib import Path

import requests

from . import config


def months_plan(today: date):
    """Yield (year, month) for every month from START_MONTH to today's month."""
    y, m = config.START_MONTH.year, config.START_MONTH.month
    while (y, m) <= (today.year, today.month):
        yield y, m
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def raw_name(year, month):
    return f"usd_myr_{year}_{month:02d}.json"


def fetch(root: Path, today: date | None = None, session=None) -> Path:
    today = today or date.today()
    out = root / config.RAW_DIR / today.isoformat() / "bnm"
    out.mkdir(parents=True, exist_ok=True)
    manifest = out / "manifest.jsonl"
    s = session or requests.Session()
    s.headers["Accept"] = config.BNM_ACCEPT

    plan = list(months_plan(today))
    for i, (year, month) in enumerate(plan, 1):
        url = config.BNM_URL.format(year=year, month=month)
        for attempt in range(5):
            resp = s.get(url, params=config.BNM_PARAMS, timeout=60)
            if resp.status_code not in (429, 500, 502, 503, 504):
                break
            time.sleep(2 ** (attempt + 1))

        # Body saved exactly as received, whatever the status.
        name = raw_name(year, month)
        (out / name).write_bytes(resp.content)
        record = {
            "file": name,
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "url": url,
            "params": config.BNM_PARAMS,
            "status": resp.status_code,
            "bytes": len(resp.content),
            "sha256": hashlib.sha256(resp.content).hexdigest(),
        }
        if resp.ok:
            try:
                body = resp.json()
                record["count"] = len((body.get("data") or {}).get("rate") or [])
                record["session"] = (body.get("meta") or {}).get("session")
            except ValueError:
                record["api_error"] = "non-JSON body"
        with manifest.open("a") as f:
            f.write(json.dumps(record) + "\n")
        print(f"[bnm {i}/{len(plan)}] {name}: HTTP {resp.status_code}, count={record.get('count')}",
              file=sys.stderr)
        time.sleep(config.BNM_SLEEP_S)
    return out
