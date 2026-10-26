"""Run the monitor end to end.

    python -m monitor.run              fetch Comtrade, ingest inbox, clean, rebuild DB, run checks,
                                       write reports/dashboard.html
    python -m monitor.run --no-fetch   same, using raw files already on disk
"""
import argparse
from pathlib import Path

from . import build_db, clean, config, dashboard, fetch_comtrade, ingest_gacc


def main(argv=None, root: Path = config.ROOT):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-fetch", action="store_true", help="skip the Comtrade API calls")
    args = ap.parse_args(argv)

    if not args.no_fetch:
        fetch_comtrade.fetch(root)
    ingest_gacc.ingest(root)
    clean.clean(root)
    build_db.snapshot_prev(root)
    con = build_db.build(root)
    page = dashboard.render(con, root)

    print("\nRun summary (sql/90_summary.sql):")
    for metric, table, detail, value in con.execute("SELECT * FROM run_summary").fetchall():
        print(f"  {metric:18} {table:24} {detail or '':32} {value}")
    print("\nBacktest (sql/checks/50_backtest_2023_carbonate.sql):")
    df = con.execute("SELECT * FROM backtest_2023_carbonate").df()
    print(df.to_string(index=False))
    print(f"\nDashboard: {page.relative_to(root)}")
    con.close()


if __name__ == "__main__":
    main()
