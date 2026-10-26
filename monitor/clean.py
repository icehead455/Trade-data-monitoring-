"""Turn raw files into the clean Parquet tables in data/clean/.

comtrade.parquet  one row per reporter, flow, partner, hs6, month (totals only:
                  partner2=World, customs=C00, mode of transport=all)
availability.parquet  one row per reporter and month Comtrade says it has released
gacc.parquet      one row per flow, hs8, partner, month (summed over any trade
                  mode / province breakdown present in the export)
"""
import json
import re
import sys
from pathlib import Path

import pandas as pd

from . import config

COMTRADE_COLUMNS = {
    "reporter_code": "Int64", "reporter_iso": "string", "reporter": "string",
    "flow": "string", "partner_code": "Int64", "partner_iso": "string", "partner": "string",
    "hs6": "string", "period": "datetime64[ms]", "net_wgt_kg": "float64",
    "kg_source": "string", "net_wgt_estimated": "boolean", "qty": "float64",
    "qty_unit": "string", "value_usd": "float64", "raw_file": "string",
}
GACC_COLUMNS = {
    "flow": "string", "hs8": "string", "hs6": "string", "description": "string",
    "partner_code": "string", "partner": "string", "period": "datetime64[ms]",
    "qty1": "float64", "unit1": "string", "qty2": "float64", "unit2": "string",
    "net_wgt_kg": "float64", "value_usd": "float64", "value_cny": "float64",
    "raw_file": "string",
}


def _empty(cols):
    return pd.DataFrame({c: pd.Series(dtype=t) for c, t in cols.items()})


# ---------------------------------------------------------------- Comtrade

def _latest_good_comtrade_files(root: Path) -> dict[str, Path]:
    """For each raw file name, the copy from the latest fetch date that returned HTTP 200."""
    best = {}
    for manifest in sorted((root / config.RAW_DIR).glob("*/comtrade/manifest.jsonl")):
        for line in manifest.read_text().splitlines():
            rec = json.loads(line)
            if rec["status"] == 200 and not rec.get("api_error"):
                best[rec["file"]] = manifest.parent / rec["file"]  # later dates overwrite
    return best


def _is_total(v, total):
    return v is None or v == total or (isinstance(v, float) and pd.isna(v))


AVAILABILITY_COLUMNS = {"reporter_code": "Int64", "period": "datetime64[ms]",
                        "last_released": "string", "raw_file": "string"}


def _month(p) -> pd.Timestamp:
    p = str(p)
    return pd.Timestamp(year=int(p[:4]), month=int(p[4:6]), day=1)


def clean_availability(root: Path) -> pd.DataFrame:
    rows = []
    for name, path in sorted(_latest_good_comtrade_files(root).items()):
        if not name.startswith("availability_"):
            continue
        for r in json.loads(path.read_bytes()).get("data") or []:
            if r.get("freqCode", "M") != "M" or "reporterCode" not in r or "period" not in r:
                continue
            rows.append({"reporter_code": r["reporterCode"], "period": _month(r["period"]),
                         "last_released": r.get("lastReleased"),
                         "raw_file": str(path.relative_to(root))})
    df = pd.DataFrame(rows) if rows else _empty(AVAILABILITY_COLUMNS)
    # A reporter can have several classification datasets per month; one row is enough.
    df = df.astype(AVAILABILITY_COLUMNS).sort_values(["reporter_code", "period", "last_released"])
    return df.drop_duplicates(["reporter_code", "period"], keep="last").reset_index(drop=True)


def clean_comtrade(root: Path) -> pd.DataFrame:
    rows = []
    for name, path in sorted(_latest_good_comtrade_files(root).items()):
        if not name.startswith("comtrade_"):
            continue
        for r in json.loads(path.read_bytes()).get("data") or []:
            if r.get("freqCode", "M") != "M":
                continue
            if not (_is_total(r.get("partner2Code"), 0) and _is_total(r.get("motCode"), 0)
                    and _is_total(r.get("customsCode"), "C00")):
                continue
            if str(r["cmdCode"]) not in config.HS6_CODES:
                continue
            kg, src = r.get("netWgt"), "netWgt"
            if (kg is None or kg == 0) and (r.get("qtyUnitAbbr") or "").lower() == "kg" and r.get("qty"):
                kg, src = r["qty"], "qty"
            if kg is None:
                src = None
            rows.append({
                "reporter_code": r["reporterCode"], "reporter_iso": r.get("reporterISO"),
                "reporter": r.get("reporterDesc"), "flow": r["flowCode"],
                "partner_code": r["partnerCode"], "partner_iso": r.get("partnerISO"),
                "partner": r.get("partnerDesc"), "hs6": str(r["cmdCode"]),
                "period": _month(r["period"]),
                "net_wgt_kg": kg, "kg_source": src,
                "net_wgt_estimated": r.get("isNetWgtEstimated"),
                "qty": r.get("qty"), "qty_unit": r.get("qtyUnitAbbr"),
                "value_usd": r.get("primaryValue"),
                "raw_file": str(path.relative_to(root)),
            })
    df = pd.DataFrame(rows) if rows else _empty(COMTRADE_COLUMNS)
    df = df.astype(COMTRADE_COLUMNS)
    key = ["reporter_code", "flow", "partner_code", "hs6", "period"]
    dup = df[df.duplicated(key, keep=False)]
    if len(dup):
        raise ValueError(f"Comtrade rows not unique on {key} after total filters:\n{dup.head(20)}")
    return df.sort_values(key).reset_index(drop=True)


# ---------------------------------------------------------------- GACC

# Header aliases: GACC Chinese export, GACC English export, and plain English.
GACC_ALIASES = {
    "period": ["数据年月", "日期", "date of data", "date", "period", "month"],
    "hs8": ["商品编码", "commodity code", "hs code", "hs8", "code"],
    "description": ["商品名称", "commodity name", "commodity", "description"],
    "partner_code": ["贸易伙伴编码", "trading partner code", "partner code"],
    "partner": ["贸易伙伴名称", "贸易伙伴", "trading partner name", "trading partner", "partner",
                "country", "origin"],
    "flow": ["进出口", "进出口标志", "贸易流向", "flow", "import/export", "trade flow"],
    "qty1": ["第一数量", "first quantity", "quantity 1", "quantity"],
    "unit1": ["第一计量单位", "first unit", "first unit of measurement", "unit 1", "unit"],
    "qty2": ["第二数量", "second quantity", "quantity 2"],
    "unit2": ["第二计量单位", "second unit", "second unit of measurement", "unit 2"],
    "value_usd": ["美元", "us dollar", "usd", "value (usd)", "value_usd", "trade value (usd)"],
    "value_cny": ["人民币", "rmb", "cny", "value (rmb)", "value_cny"],
}
KG_FACTORS = {"千克": 1.0, "公斤": 1.0, "kg": 1.0, "kilogram": 1.0, "kilograms": 1.0,
              "吨": 1000.0, "t": 1000.0, "ton": 1000.0, "tons": 1000.0, "tonne": 1000.0,
              "tonnes": 1000.0, "克": 0.001, "g": 0.001, "gram": 0.001}
FLOW_WORDS = {"进口": "M", "import": "M", "imports": "M", "m": "M",
              "出口": "X", "export": "X", "exports": "X", "x": "X"}


def _read_csv(path: Path) -> pd.DataFrame:
    for enc in ("utf-8-sig", "gb18030"):
        try:
            return pd.read_csv(path, dtype=str, encoding=enc)
        except UnicodeDecodeError:
            continue
    raise ValueError(f"{path}: not UTF-8 or GB18030")


def _map_headers(df: pd.DataFrame, path: Path) -> pd.DataFrame:
    norm = {c: re.sub(r"\s+", " ", str(c)).strip().lower() for c in df.columns}
    rename = {}
    for target, aliases in GACC_ALIASES.items():
        for col, n in norm.items():
            if n in aliases and col not in rename and target not in rename.values():
                rename[col] = target
    df = df.rename(columns=rename)[list(rename.values())]
    missing = {"period", "hs8", "partner"} - set(df.columns)
    if not ({"value_usd", "value_cny"} & set(df.columns)):
        missing.add("value_usd or value_cny")
    if missing:
        raise ValueError(f"{path}: cannot find columns {sorted(missing)}; headers were {list(norm)}")
    return df


def _flow_from_name(path: Path):
    name = path.name.lower()
    hits = {v for k, v in FLOW_WORDS.items() if len(k) > 1 and k in name}
    return hits.pop() if len(hits) == 1 else None


def _num(s: pd.Series) -> pd.Series:
    return pd.to_numeric(s.str.replace(",", "", regex=False).str.strip().replace({"": None, "-": None}),
                         errors="coerce")


def _period(s: pd.Series, path: Path) -> pd.Series:
    digits = s.str.replace(r"\D", "", regex=True)
    bad = ~digits.str.fullmatch(r"\d{6}")
    if bad.any():
        raise ValueError(f"{path}: unparseable periods {s[bad].unique()[:5].tolist()}")
    return pd.to_datetime(digits + "01", format="%Y%m%d")


def _kg(qty: pd.Series, unit: pd.Series) -> pd.Series:
    f = unit.fillna("").str.strip().str.lower().map(KG_FACTORS)
    return qty * f


def parse_gacc_file(path: Path, root: Path) -> pd.DataFrame:
    df = _map_headers(_read_csv(path), path)
    df = df[df["hs8"].notna()].copy()
    df["hs8"] = df["hs8"].str.replace(r"\D", "", regex=True)
    df = df[df["hs8"].str.len() == 8]  # drops subtotal / footer lines
    if "flow" in df.columns:
        df["flow"] = df["flow"].str.strip().str.lower().map(FLOW_WORDS)
        if df["flow"].isna().any():
            raise ValueError(f"{path}: unrecognised flow values")
    else:
        flow = _flow_from_name(path)
        if flow is None:
            raise ValueError(f"{path}: no flow column and file name does not say import/进口 or export/出口")
        df["flow"] = flow
    df["hs6"] = df["hs8"].str[:6]
    df = df[df["hs6"].isin(config.HS6_CODES)]
    df["period"] = _period(df["period"], path)
    for c in ["qty1", "qty2", "value_usd", "value_cny"]:
        df[c] = _num(df[c]) if c in df.columns else float("nan")
    for c in ["unit1", "unit2", "description", "partner_code"]:
        if c not in df.columns:
            df[c] = None
    kg1, kg2 = _kg(df["qty1"], df["unit1"]), _kg(df["qty2"], df["unit2"])
    df["net_wgt_kg"] = kg1.fillna(kg2)
    df["partner"] = df["partner"].str.strip()
    key = ["flow", "hs8", "partner", "period"]
    agg = (df.groupby(key, dropna=False)
             .agg(hs6=("hs6", "first"), description=("description", "first"),
                  partner_code=("partner_code", "first"),
                  qty1=("qty1", lambda s: s.sum(min_count=1)), unit1=("unit1", "first"),
                  qty2=("qty2", lambda s: s.sum(min_count=1)), unit2=("unit2", "first"),
                  net_wgt_kg=("net_wgt_kg", lambda s: s.sum(min_count=1)),
                  value_usd=("value_usd", lambda s: s.sum(min_count=1)),
                  value_cny=("value_cny", lambda s: s.sum(min_count=1)))
             .reset_index())
    agg["raw_file"] = str(path.relative_to(root))
    return agg


def clean_gacc(root: Path) -> pd.DataFrame:
    # Raw dirs are named by date, so sorting puts later copies last; a later file
    # wins for any (flow, hs8, partner, month) it also covers.
    paths = sorted(p for p in (root / config.RAW_DIR).glob("*/gacc/*") if p.suffix.lower() == ".csv")
    frames = [parse_gacc_file(p, root) for p in paths]
    frames = [f for f in frames if len(f)]
    if not frames:
        return _empty(GACC_COLUMNS)
    df = pd.concat(frames, ignore_index=True)
    key = ["flow", "hs8", "partner", "period"]
    df = df.drop_duplicates(key, keep="last")
    return df[list(GACC_COLUMNS)].astype(GACC_COLUMNS).sort_values(key).reset_index(drop=True)


def clean(root: Path) -> dict[str, int]:
    out = root / config.CLEAN_DIR
    out.mkdir(parents=True, exist_ok=True)
    counts = {}
    for name, df in [("comtrade", clean_comtrade(root)),
                     ("availability", clean_availability(root)),
                     ("gacc", clean_gacc(root))]:
        df.to_parquet(out / f"{name}.parquet", index=False)
        counts[name] = len(df)
        print(f"clean: {name}.parquet {len(df)} rows", file=sys.stderr)
    return counts
