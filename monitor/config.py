"""Fixed scope of the monitor. Change scope here, not in individual modules."""
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

HS6_CODES = ["284610", "284690", "280530", "261220", "253090"]

START_MONTH = date(2019, 1, 1)

MALAYSIA = 458

# Comtrade M49 codes of the partners whose imports-from-Malaysia we pull.
MIRROR_REPORTERS = {
    156: "China",
    344: "Hong Kong",
    392: "Japan",
    410: "South Korea",
    764: "Thailand",
    704: "Vietnam",
    702: "Singapore",
    842: "United States",
}

COMTRADE_URL = "https://comtradeapi.un.org/data/v1/get/C/M/HS"
COMTRADE_DA_URL = "https://comtradeapi.un.org/data/v1/getDa/C/M/HS"
COMTRADE_KEY_ENV = "COMTRADE_KEY"
# The API accepts at most 12 periods per call; we fetch one calendar year per call.
COMTRADE_SLEEP_S = 1.5

RAW_DIR = "data/raw"
INBOX_CHINA = "data/inbox/china"
CLEAN_DIR = "data/clean"
SQL_DIR = "sql"
REPORTS_DIR = "reports"
BUILD_DIR = "build"
DB_FILE = "build/monitor.duckdb"
