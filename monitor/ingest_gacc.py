"""Copy GACC CSVs from data/inbox/china/ into data/raw/<date>/gacc/ unchanged.

A file whose exact bytes already sit in any raw directory is not copied again.
Parsing happens in clean.py, always from the raw copy.
"""
import hashlib
import shutil
import sys
from datetime import date
from pathlib import Path

from . import config


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ingest(root: Path, today: date | None = None) -> list[Path]:
    today = today or date.today()
    inbox = root / config.INBOX_CHINA
    files = sorted(p for p in inbox.glob("*") if p.suffix.lower() == ".csv")
    if not files:
        return []
    seen = {_sha(p) for p in (root / config.RAW_DIR).glob("*/gacc/*") if p.is_file()}
    out = root / config.RAW_DIR / today.isoformat() / "gacc"
    copied = []
    for src in files:
        if _sha(src) in seen:
            continue
        out.mkdir(parents=True, exist_ok=True)
        dst = out / src.name
        if dst.exists():  # same name, different bytes, same day
            dst = out / f"{src.stem}.{_sha(src)[:8]}{src.suffix}"
        shutil.copyfile(src, dst)
        seen.add(_sha(dst))
        copied.append(dst)
        print(f"gacc: ingested {src.name} -> {dst.relative_to(root)}", file=sys.stderr)
    return copied
