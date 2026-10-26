"""End-to-end pipeline test on SYNTHETIC fixtures in a temp directory.

The numbers below are invented to exercise the code paths. They are never
written under the real data/ directory and must never be quoted anywhere.
"""
import json
import shutil
import subprocess
from pathlib import Path

import duckdb
import pytest

from monitor import build_db, clean, config, dashboard, fetch_comtrade, ingest_gacc
from monitor.run import main

REPO = Path(__file__).resolve().parent.parent


def ct_row(reporter, flow, partner, hs6, period, kg, usd, **kw):
    r = {"freqCode": "M", "reporterCode": reporter, "reporterISO": "X", "reporterDesc": "X",
         "flowCode": flow, "partnerCode": partner, "partnerISO": "X", "partnerDesc": "X",
         "partner2Code": 0, "customsCode": "C00", "motCode": 0, "cmdCode": hs6,
         "period": period, "netWgt": kg, "isNetWgtEstimated": False, "qty": kg,
         "qtyUnitAbbr": "kg", "primaryValue": usd}
    r.update(kw)
    return r


def write_raw(root, date, name, body, status=200):
    d = root / "data/raw" / date / "comtrade"
    d.mkdir(parents=True, exist_ok=True)
    (d / name).write_text(json.dumps(body))
    with (d / "manifest.jsonl").open("a") as f:
        f.write(json.dumps({"file": name, "status": status}) + "\n")


@pytest.fixture
def root(tmp_path):
    shutil.copytree(REPO / "sql", tmp_path / "sql")
    (tmp_path / "data/inbox/china").mkdir(parents=True)
    my = [ct_row(458, "X", 156, "284690", p, kg, kg * 5)
          for p, kg in [("202301", 2000), ("202302", 50000), ("202303", 60000), ("202304", 1000)]]
    my.append(ct_row(458, "X", 156, "284690", "202302", 99, 1, motCode=1000))  # breakdown, dropped
    my.append(ct_row(458, "X", 0, "284690", "202302", 50000, 250000))          # World
    write_raw(tmp_path, "2026-10-01", "comtrade_r458_X_pall_2023.json", {"data": my})
    cn = [ct_row(156, "M", 458, "284690", p, kg, kg * 6)
          for p, kg in [("202303", 45000), ("202304", 58000), ("202305", 900)]]
    write_raw(tmp_path, "2026-10-01", "comtrade_r156_M_p458_2023.json", {"data": cn})
    write_raw(tmp_path, "2026-10-01", "availability_r458.json",
              {"data": [{"reporterCode": 458, "period": f"2023{m:02d}"} for m in range(1, 7)]})
    write_raw(tmp_path, "2026-10-01", "availability_r156.json",
              {"data": [{"reporterCode": 156, "period": f"2023{m:02d}"} for m in range(1, 7)]})
    # A later fetch that failed must not displace the good one.
    write_raw(tmp_path, "2026-10-02", "comtrade_r156_M_p458_2023.json", {"error": "x"}, status=429)

    csv = ("数据年月,商品编码,商品名称,贸易伙伴编码,贸易伙伴名称,第一数量,第一计量单位,第二数量,第二计量单位,美元\n"
           "202302,28469048,碳酸镧,112,马来西亚,\"1,000\",千克,,,5000\n"
           "202303,28469048,碳酸镧,112,马来西亚,40000,千克,,,200000\n"
           "202303,28469048,碳酸镧,112,马来西亚,500,千克,,,2500\n"
           "202304,28469019,其他稀土氧化物,112,马来西亚,7000,千克,,,70000\n"
           "202305,28469048,碳酸镧,112,马来西亚,30000,千克,,,150000\n"
           "202305,85011000,微电机,112,马来西亚,1,千克,,,1\n"
           "合计,,,,,,,,,\n")
    (tmp_path / "data/inbox/china/gacc_import_2023.csv").write_bytes(csv.encode("gb18030"))
    return tmp_path


def q(root, sql):
    con = duckdb.connect(str(root / config.DB_FILE), read_only=True)
    try:
        return con.execute(sql).fetchall()
    finally:
        con.close()


def test_end_to_end(root):
    main(["--no-fetch"], root=root)

    raw = list((root / "data/raw").glob("*/gacc/*.csv"))
    assert len(raw) == 1
    assert raw[0].read_bytes() == (root / "data/inbox/china/gacc_import_2023.csv").read_bytes()
    for t in ["comtrade", "gacc", "availability"]:
        assert (root / "data/clean" / f"{t}.parquet").exists()
    for t in ["mirror_gap", "unit_value", "mom_jumps", "snapshot_diff", "backtest_2023_carbonate",
              "run_summary"]:
        assert (root / "reports" / f"{t}.csv").exists()

    # totals only, World kept as its own partner
    assert q(root, "SELECT net_wgt_kg FROM comtrade WHERE reporter_code=458 AND partner_code=156 "
                   "AND period='2023-02-01'") == [(50000,)]
    # GACC: thousands separator, summed duplicate lines, non-scope HS and footer dropped
    assert q(root, "SELECT net_wgt_kg FROM gacc WHERE period='2023-03-01'") == [(40500,)]
    assert q(root, "SELECT count(*) FROM gacc WHERE hs6 <> '284690'") == [(0,)]

    gap = dict(q(root, "SELECT strftime(period,'%m'), gap_kg FROM mirror_gap "
                       "WHERE mirror_source='comtrade' AND hs6='284690'"))
    assert gap["02"] == -50000          # China released Feb, filed nothing -> 0
    assert gap["03"] == 45000 - 60000
    assert gap["05"] == 900             # Malaysia released May, filed nothing -> 0

    flags = dict(q(root, "SELECT strftime(period,'%Y-%m'), flag FROM mom_jumps "
                         "WHERE source='comtrade' AND reporter='458' AND partner='156'"))
    assert flags["2023-02"] == "up" and flags["2023-04"] == "down" and flags["2023-05"] == "vanished"

    bt = {r[0]: r for r in q(root, "SELECT month, verdict, china_basis, months_matched "
                                   "FROM backtest_2023_carbonate")}
    assert bt["window"][1:] == ("PASS", "gacc_hs8_carbonate", 3)

    # no git repo -> no snapshot, everything shows as added
    assert q(root, "SELECT has_snapshot FROM snapshot_meta") == [(False,)]
    assert q(root, "SELECT DISTINCT change FROM snapshot_diff") == [("added",)]



def dash_table(page, name):
    data = json.loads(page.split("const DATA = ", 1)[1].split(";\n", 1)[0])
    t = data[name]
    return [dict(zip(t["columns"], r)) for r in t["rows"]]


def test_dashboard(root):
    main(["--no-fetch"], root=root)
    page = (root / "reports/dashboard.html").read_text(encoding="utf-8")
    assert dashboard.PLACEHOLDER not in page

    # World row; released month without a row -> 0; unreleased month -> null
    ex = {r["month"]: r["t"] for r in dash_table(page, "dash_exports_monthly") if r["hs6"] == "284690"}
    assert ex["2023-02"] == 50 and ex["2023-01"] == 0 and ex["2022-12"] is None
    assert max(ex) == "2023-06"

    k = {r["hs6"]: r for r in dash_table(page, "dash_kpis")}["284690"]
    assert (k["latest_month"], k["t_12m"], k["months_released_12m"]) == ("2023-06", 50, 6)

    mm = {(r["mirror_source"], r["month"]): r for r in dash_table(page, "dash_mirror_monthly")
          if r["partner_code"] == 156 and r["hs6"] == "284690"}
    assert (mm["comtrade", "2023-03"]["my_t"], mm["comtrade", "2023-03"]["mirror_t"]) == (60, 45)
    assert (mm["comtrade", "2023-06"]["my_t"], mm["comtrade", "2023-06"]["mirror_t"]) == (0, 0)
    assert mm["comtrade", "2022-12"]["mirror_t"] is None
    assert mm["gacc", "2023-03"]["mirror_t"] == 40.5

    s = {(r["win"], r["mirror_source"]): r for r in dash_table(page, "dash_mirror_summary")
         if r["partner_code"] == 156 and r["hs6"] == "284690"}
    assert (s["all", "comtrade"]["my_t"], s["all", "comtrade"]["mirror_t"]) == (113, 103.9)
    assert s["all", "comtrade"]["months_compared"] == 6

    assert [r["partner_code"] for r in dash_table(page, "dash_destinations")
            if r["win"] == "all" and r["hs6"] == "284690"] == [156]
    assert dash_table(page, "dash_status")[0]["backtest_verdict"] == "PASS"


def test_dashboard_keeps_data_inside_script(tmp_path):
    con = duckdb.connect()
    con.execute("CREATE TABLE dash_x AS SELECT '</script><b>' AS s")
    page = dashboard.render(con, tmp_path).read_text(encoding="utf-8")
    assert "</script><b>" not in page
    assert dash_table(page, "dash_x") == [{"s": "</script><b>"}]


def test_snapshot_diff_against_head(root):
    main(["--no-fetch"], root=root)
    git = lambda *a: subprocess.run(["git", *a], cwd=root, check=True, capture_output=True)
    git("init", "-q")
    git("add", "data/clean")
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "snapshot")

    # a revision arrives: Malaysia's March figure changes
    p = root / "data/raw/2026-10-01/comtrade/comtrade_r458_X_pall_2023.json"
    body = json.loads(p.read_text())
    for r in body["data"]:
        if r["period"] == "202303" and r["partnerCode"] == 156:
            r["netWgt"] = 61000
    write_raw(root, "2026-10-03", p.name, body)

    main(["--no-fetch"], root=root)
    assert q(root, "SELECT change, prev_kg, kg FROM snapshot_diff") == [("changed", 60000, 61000)]


def test_backtest_no_data_without_coverage(root):
    for p in (root / "data/raw/2026-10-01/comtrade").glob("availability_*"):
        p.write_text(json.dumps({"data": []}))
    (root / "data/inbox/china/gacc_import_2023.csv").unlink()
    main(["--no-fetch"], root=root)
    # China Comtrade proxy has no Feb row and Feb is not released -> NO_DATA
    assert q(root, "SELECT verdict, china_basis FROM backtest_2023_carbonate WHERE month='window'") == \
        [("NO_DATA", "comtrade_hs6_284690_proxy")]


def test_gacc_without_flow_is_rejected(root):
    src = root / "data/inbox/china/gacc_import_2023.csv"
    src.rename(src.with_name("gacc_2023.csv"))
    ingest_gacc.ingest(root)
    with pytest.raises(ValueError, match="flow"):
        clean.clean_gacc(root)


def test_ingest_is_idempotent(root):
    ingest_gacc.ingest(root)
    assert ingest_gacc.ingest(root) == []


def test_sql_partners_match_config():
    con = duckdb.connect()
    con.execute("CREATE TABLE mirror_partners (code INTEGER, name VARCHAR)")
    load = (REPO / "sql/00_load.sql").read_text()
    stmt = load[load.index("INSERT INTO mirror_partners"):].split(";")[0]
    con.execute(stmt)
    assert dict(con.execute("SELECT * FROM mirror_partners").fetchall()) == config.MIRROR_REPORTERS


def test_fetch_plan_and_raw_bytes(tmp_path, monkeypatch):
    from datetime import date

    plan = list(fetch_comtrade.requests_plan(date(2026, 10, 26)))
    assert len(plan) == 9 * 8
    assert plan[0][4][0] == "201901" and plan[-1][4][-1] == "202610"
    assert all(len(p[4]) <= 12 for p in plan)

    class Resp:
        status_code, ok = 200, True
        content = b'{"count": 0, "data": [],   "error": ""}'
        def json(self): return json.loads(self.content)

    class Sess:
        headers = {}
        calls = []
        def get(self, url, params, timeout):
            self.calls.append(params)
            return Resp()

    monkeypatch.setenv("COMTRADE_KEY", "test-key-not-real")
    monkeypatch.setattr(fetch_comtrade.config, "COMTRADE_SLEEP_S", 0)
    out = fetch_comtrade.fetch(tmp_path, today=date(2019, 3, 5), session=Sess())
    files = sorted(p.name for p in out.iterdir())
    assert "comtrade_r458_X_pall_2019.json" in files
    assert (out / "comtrade_r458_X_pall_2019.json").read_bytes() == Resp.content
    assert "test-key-not-real" not in (out / "manifest.jsonl").read_text()
