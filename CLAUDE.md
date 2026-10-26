# Malaysian rare earth export monitor

Tracks Malaysia's exports of rare earth products against what its trading
partners say they imported, using UN Comtrade and China's GACC (customs) data.

## Scope

- HS codes: 284610 (cerium compounds), 284690 (other rare earth compounds),
  280530 (rare earth metals), 261220 (monazite), 253090 (other mineral
  substances). Monthly data, January 2019 onward.
- Comtrade, Malaysia (458) as reporter: exports to every partner.
- Comtrade, these partners as reporters: imports from Malaysia. China 156,
  Hong Kong 344, Japan 392, South Korea 410, Thailand 764, Vietnam 704,
  Singapore 702, US 842.
- GACC: any CSV dropped into `data/inbox/china/` (China's 8-digit lines).
- Bank Negara Malaysia: daily USD/MYR noon (12:00) middle rates from its open
  API (`api.bnm.gov.my`, no key), one call per month, to show values in ringgit.
- Scope is set in `monitor/config.py`. The partner list is also in
  `sql/00_load.sql`, and a test checks that the two match.

## Running

```
pip install -r requirements.txt
export COMTRADE_KEY=...          # Comtrade subscription key, read from the environment only
python -m monitor.run            # fetch (Comtrade, BNM) + ingest + clean + rebuild DB + run every check + dashboard
python -m monitor.run --no-fetch # rerun on the raw files already on disk
python -m pytest -q tests
```

## Rules

1. **Raw data is never changed.** Every API response body is saved byte for
   byte under `data/raw/<fetch-date>/comtrade/` (BNM: `.../bnm/`), error
   responses included.
   Each request goes in the `manifest.jsonl` next to it (URL, params, HTTP
   status, sha256). GACC CSVs are copied byte for byte from the inbox into
   `data/raw/<fetch-date>/gacc/`. Never edit, reformat or delete anything
   under `data/raw/`. Parsing always reads the raw copy, never the inbox.
2. **The API key stays in the environment.** Read `COMTRADE_KEY` from the
   environment only. Never write it to a file, a log, the manifest, a commit
   or a message.
3. **Clean tables are Parquet**, written only by `monitor/clean.py` to
   `data/clean/`: `comtrade.parquet`, `availability.parquet`,
   `gacc.parquet` and `fx.parquet`. For each raw file, the copy from the latest fetch date
   that returned HTTP 200 is used. For Comtrade only total rows are kept
   (partner2 = World, customs = C00, transport mode = all). Duplicates fail
   the run; they are never silently dropped.
4. **Every check is a `.sql` file run in DuckDB.** The run order is
   `sql/00_load.sql`, then `sql/checks/*.sql` by file name, then
   `sql/80_dashboard.sql`, then `sql/90_summary.sql`. `sql/checks/NN_<name>.sql` must create table
   `<name>`, which is exported to `reports/<name>.csv`. Don't compute check
   results in Python or pandas.
5. **The `.duckdb` file is rebuilt from scratch on every run** at
   `build/monitor.duckdb`. It is gitignored, as is `build/`, and is never
   committed.
6. **The snapshot is git.** The snapshot diff compares this run's
   `data/clean/*.parquet` against the versions at `git HEAD`. After you
   review a run, commit `data/raw/`, `data/clean/` and `reports/` together,
   so the next run diffs against that state.
7. **Every figure in a memo comes from a query in `sql/`, and the memo cites
   it.** Cite the file path plus the table, filter or row the number came
   from. Example: "Malaysia exported X kg of 284690 to China in Mar 2023
   (`sql/checks/10_mirror_gap.sql`, `mirror_gap`, partner 156, hs6 284690,
   2023-03, `my_kg`)." If you need a number that no query produces, add a
   `.sql` file under `sql/` first, run it through the pipeline, then cite
   it. Don't use numbers from ad hoc Python, from memory, from the test
   fixtures, or from outside sources.
8. **Test fixtures are synthetic.** The numbers in `tests/` are made up.
   They are only written to temp directories and must never be quoted.

## Checks

| File | Table | What it does |
|---|---|---|
| `sql/checks/10_mirror_gap.sql` | `mirror_gap` | Tonnage gap by partner, HS6 and month: Malaysia's reported exports vs. the partner's imports from Malaysia (Comtrade; for China also GACC summed to HS6). Includes the partner's figure for the following month to allow for shipping lag. |
| `sql/checks/20_unit_value.sql` | `unit_value` | USD per kg for every series and month, flagged when ≥3× or ≤⅓ of the series median (shipments ≥1 t only). |
| `sql/checks/30_mom_jumps.sql` | `mom_jumps` | Month-on-month tonnage moves of ≥3×, and series appearing from or dropping to zero (≥1 t). |
| `sql/checks/40_snapshot_diff.sql` | `snapshot_diff` | Rows added, removed or revised compared with the last committed `data/clean/`. |
| `sql/checks/50_backtest_2023_carbonate.sql` | `backtest_2023_carbonate` | The backtest below. |
| `sql/90_summary.sql` | `run_summary` | Counts and the verdict that `monitor.run` prints. |

### Dashboard

Every run writes `reports/dashboard.html`, one self-contained page (open it in a
browser; no server). Pick an HS code, a window (since Jan 2019, 36 or 12
months) and a currency (RM or US$) to see Malaysia's monthly exports to the world, top destinations, the
mirror check per partner, flags, revisions since the last commit and coverage.

- Its figures are the `dash_*` tables from `sql/80_dashboard.sql`, embedded
  as JSON by `monitor/dashboard.py`. The page only filters and draws them.
  To show a new figure, add it to `sql/80_dashboard.sql`, not to the page
  or to Python.
- For a memo, cite the table, not the page: "(`sql/80_dashboard.sql`,
  `dash_kpis`, hs6 284690, `t_12m`)".
- The layout and charts are in `monitor/dashboard_template.html`.
- It is committed with `reports/` after review, like the CSVs.

### Backtest

Feb–Apr 2023 should show rare earth carbonate going from Malaysia to China in
both sources, with China's side allowed to land one month later (so China's
window is Feb–May). The verdict is in the `window` row:

- `PASS`: both sides are above zero within their windows.
- `FAIL`: one side is zero across its whole window.
- `NO_DATA`: some month in a window is not released or not covered.

`months_matched` counts the months m where Malaysia(m) > 0 and
China(m or m+1) > 0.

## How to read the data

- **Zero versus unknown.** Comtrade sends no row when there was no trade.
  A month counts as released if the availability endpoint lists it, or if
  we hold any row for that reporter in that month. In a released month a
  missing row means 0. In a month that isn't released the value is NULL.
  For GACC, a month counts as covered if any CSV contains it, so drop in
  complete exports.
- **Carbonate is only visible in GACC.** Comtrade is HS6, and 284690 lumps
  carbonate in with every other rare earth compound. So Malaysia's side of
  the backtest is all of 284690. On China's side, carbonate lines are the
  GACC lines under 2846 whose description contains 碳酸 or "carbonate".
  Check this against China's tariff schedule for the year in question. If
  GACC doesn't cover Feb–May 2023, the backtest falls back to China's
  Comtrade 284690 as a proxy and says so in `china_basis`.
- **Mirror direction.** Partners record imports by country of origin;
  Malaysia records exports by destination. Hong Kong and Singapore
  re-exports make those two gaps structural. Imports are valued CIF and
  exports FOB, so unit values for the two sides differ by freight.
- **Ringgit.** Comtrade values are in US$. The `rm` columns in
  `sql/80_dashboard.sql` convert each month at Bank Negara's average noon
  middle rate for that month (`fx_monthly` in `sql/00_load.sql`). A ringgit
  total is NULL, never understated, if any month in it lacks a rate. Mirror
  ratios and the flags stay in US$. Converted figures can differ slightly
  from DOSM's own ringgit figures, so check a headline number against DOSM.
- **GACC CSVs.** Chinese or English GACC headers are accepted, encoded in
  UTF-8 or GB18030. If the file has no flow column, its name must say
  `import`/`进口` or `export`/`出口`, otherwise the run fails. Weights are
  taken from whichever quantity column is a mass unit (千克, 吨 and so on).
  RMB values are kept as `value_cny` and not converted. Lines outside the
  five HS6 codes, and subtotal lines, are dropped.
