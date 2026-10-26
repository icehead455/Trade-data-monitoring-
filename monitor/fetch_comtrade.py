"""Fetch monthly UN Comtrade data and save every response body unchanged.

One data call per (reporter, flow, calendar year), plus one data-availability
call per reporter so that "no row" can be told apart from "not yet released".
Response bodies are written byte-for-byte to data/raw/<fetch-date>/comtrade/; request metadata (never the
key) goes to a sidecar manifest.jsonl in the same directory.
"""
import hashlib
import json
import os
import sys
import time
from datetime import date, datetime, timezone
from pathlib import Path

import requests

from . import config


def requests_plan(today: date):
    """Yield (reporter, flow, partner, year, periods) for every call to make."""
    last = date(today.year, today.month, 1)
    calls = [(config.MALAYSIA, "X", None)]  # Malaysia exports, all partners
    calls += [(r, "M", config.MALAYSIA) for r in config.MIRROR_REPORTERS]
    for year in range(config.START_MONTH.year, last.year + 1):
        periods = [
            f"{year}{m:02d}"
            for m in range(1, 13)
            if date(year, m, 1) >= config.START_MONTH and date(year, m, 1) <= last
        ]
        for reporter, flow, partner in calls:
            yield reporter, flow, partner, year, periods


def availability_plan():
    """One data-availability call per reporter: which months it has released."""
    return [config.MALAYSIA, *config.MIRROR_REPORTERS]


def raw_name(reporter, flow, partner, year):
    p = "all" if partner is None else str(partner)
    return f"comtrade_r{reporter}_{flow}_p{p}_{year}.json"


def fetch(root: Path, today: date | None = None, session=None) -> Path:
    key = os.environ.get(config.COMTRADE_KEY_ENV)
    if not key:
        raise SystemExit(f"{config.COMTRADE_KEY_ENV} is not set; cannot fetch from Comtrade.")
    today = today or date.today()
    out = root / config.RAW_DIR / today.isoformat() / "comtrade"
    out.mkdir(parents=True, exist_ok=True)
    manifest = out / "manifest.jsonl"
    s = session or requests.Session()
    s.headers["Ocp-Apim-Subscription-Key"] = key

    plan = [(config.COMTRADE_DA_URL, {"reporterCode": r}, f"availability_r{r}.json")
            for r in availability_plan()]
    for reporter, flow, partner, year, periods in requests_plan(today):
        params = {
            "reporterCode": reporter,
            "flowCode": flow,
            "cmdCode": ",".join(config.HS6_CODES),
            "period": ",".join(periods),
            "includeDesc": "true",
        }
        if partner is not None:
            params["partnerCode"] = partner
        plan.append((config.COMTRADE_URL, params, raw_name(reporter, flow, partner, year)))

    for i, (url, params, name) in enumerate(plan, 1):
        for attempt in range(5):
            resp = s.get(url, params=params, timeout=120)
            if resp.status_code not in (429, 500, 502, 503, 504):
                break
            time.sleep(2 ** (attempt + 1))

        # Body saved exactly as received, whatever the status.
        (out / name).write_bytes(resp.content)
        record = {
            "file": name,
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "url": url,
            "params": params,
            "status": resp.status_code,
            "bytes": len(resp.content),
            "sha256": hashlib.sha256(resp.content).hexdigest(),
        }
        if resp.ok:
            try:
                body = resp.json()
                record["count"] = body.get("count")
                record["api_error"] = body.get("error") or None
            except ValueError:
                record["api_error"] = "non-JSON body"
        with manifest.open("a") as f:
            f.write(json.dumps(record) + "\n")
        print(f"[{i}/{len(plan)}] {name}: HTTP {resp.status_code}, count={record.get('count')}",
              file=sys.stderr)
        time.sleep(config.COMTRADE_SLEEP_S)
    return out
