-- Dashboard tables. monitor/dashboard.py embeds every dash_* table in
-- reports/dashboard.html as it is and only draws it, so every figure on the page
-- comes from this file. Cite it like a check: "sql/80_dashboard.sql, dash_kpis,
-- hs6 284690, t_12m".
--
-- Weights are tonnes (kg / 1000, kept to the kg). Malaysia's totals are its own
-- "World" row (partner 0). As in the checks, a month the reporter has released
-- but filed no row for is 0, and a month it has not released is NULL.
-- Windows end at Malaysia's latest released month.
--
-- Ringgit (rm) columns convert each month's USD at Bank Negara's average noon
-- middle rate for that month (fx_monthly, sql/00_load.sql). A ringgit total is
-- NULL, never smaller, when any month in it has a USD value but no rate.

-- Comtrade rows with their value in ringgit (NULL where the month has no rate).
CREATE OR REPLACE TABLE comtrade_rm AS
SELECT c.*, c.value_usd * f.usd_myr AS value_rm
FROM comtrade c
LEFT JOIN fx_monthly f ON f.period = c.period;

CREATE OR REPLACE TABLE dash_products (hs6 VARCHAR, code VARCHAR, label VARCHAR, sort INTEGER);
INSERT INTO dash_products VALUES
    ('284690', '2846.90', 'Rare earth compounds, other than cerium', 1),
    ('284610', '2846.10', 'Cerium compounds', 2),
    ('280530', '2805.30', 'Rare earth metals, scandium and yttrium', 3),
    ('261220', '2612.20', 'Thorium ores and concentrates (monazite)', 4),
    ('253090', '2530.90', 'Other mineral substances', 5);

CREATE OR REPLACE TABLE dash_meta AS
SELECT
    (SELECT strftime(max(period), '%Y-%m') FROM reporter_periods WHERE reporter_code = 458) AS my_latest_month,
    (SELECT max(regexp_extract(raw_file, 'data/raw/([^/]+)/', 1))
     FROM (SELECT raw_file FROM comtrade UNION ALL SELECT raw_file FROM gacc))             AS latest_fetch,
    (SELECT has_snapshot FROM snapshot_meta)                                                AS has_snapshot,
    (SELECT "commit" FROM snapshot_meta)                                                    AS snapshot_commit,
    (SELECT count(*) > 0 FROM gacc_periods WHERE flow = 'M')                                AS has_gacc_imports,
    (SELECT strftime(max(period), '%Y-%m') FROM fx_monthly)                                 AS fx_latest_month;

-- The exchange rates the ringgit columns use, one row per month.
CREATE OR REPLACE TABLE dash_fx_monthly AS
SELECT strftime(period, '%Y-%m') AS month, round(usd_myr, 4) AS usd_myr, days
FROM fx_monthly
WHERE period >= DATE '2019-01-01'
ORDER BY period;

CREATE OR REPLACE TABLE dash_windows AS
WITH e AS (SELECT max(period) AS m FROM reporter_periods WHERE reporter_code = 458)
SELECT 'all' AS win, 'Since Jan 2019' AS label, 1 AS sort, DATE '2019-01-01' AS start_month, m AS end_month FROM e
UNION ALL SELECT '36m', 'Last 36 months', 2, (m - INTERVAL 35 MONTH)::DATE, m FROM e
UNION ALL SELECT '12m', 'Last 12 months', 3, (m - INTERVAL 11 MONTH)::DATE, m FROM e
ORDER BY sort;

-- Malaysia's exports to the world, every product and month from Jan 2019.
CREATE OR REPLACE TABLE dash_exports_monthly AS
WITH months AS (
    SELECT unnest(generate_series(DATE '2019-01-01', (SELECT end_month FROM dash_windows WHERE win = 'all'),
                                  INTERVAL 1 MONTH))::DATE AS period
)
SELECT
    p.hs6, strftime(m.period, '%Y-%m') AS month,
    CASE WHEN c.period IS NOT NULL THEN round(c.net_wgt_kg / 1000, 3)
         WHEN r.period IS NOT NULL THEN 0 END                       AS t,
    CASE WHEN c.period IS NOT NULL THEN c.value_usd
         WHEN r.period IS NOT NULL THEN 0 END                       AS usd,
    round(c.value_usd / nullif(c.net_wgt_kg, 0), 2)                 AS usd_per_kg,
    CASE WHEN c.period IS NOT NULL THEN round(c.value_rm, 2)
         WHEN r.period IS NOT NULL THEN 0 END                       AS rm,
    round(c.value_rm / nullif(c.net_wgt_kg, 0), 2)                  AS rm_per_kg
FROM dash_products p
CROSS JOIN months m
LEFT JOIN comtrade_rm c ON c.reporter_code = 458 AND c.flow = 'X' AND c.partner_code = 0
                    AND c.hs6 = p.hs6 AND c.period = m.period
LEFT JOIN reporter_periods r ON r.reporter_code = 458 AND r.period = m.period
ORDER BY p.sort, m.period;

-- Headline figures per product: the last 12 released months against the 12 before.
CREATE OR REPLACE TABLE dash_kpis AS
WITH e AS (SELECT end_month AS m FROM dash_windows WHERE win = 'all'),
x AS (
    SELECT c.hs6, c.period, c.net_wgt_kg AS kg, c.value_usd AS usd, c.value_rm AS rm
    FROM comtrade_rm c
    WHERE c.reporter_code = 458 AND c.flow = 'X' AND c.partner_code = 0
),
agg AS (
    SELECT
        p.hs6,
        sum(x.kg)  FILTER (WHERE x.period > e.m - INTERVAL 12 MONTH)                                    AS kg_12m,
        sum(x.kg)  FILTER (WHERE x.period <= e.m - INTERVAL 12 MONTH AND x.period > e.m - INTERVAL 24 MONTH) AS kg_prev_12m,
        sum(x.usd) FILTER (WHERE x.period > e.m - INTERVAL 12 MONTH)                                    AS usd_12m,
        sum(x.usd) FILTER (WHERE x.period <= e.m - INTERVAL 12 MONTH AND x.period > e.m - INTERVAL 24 MONTH) AS usd_prev_12m,
        sum(x.usd) FILTER (WHERE x.period > e.m - INTERVAL 12 MONTH AND x.kg > 0)                       AS usd_12m_weighed,
        sum(x.kg)  FILTER (WHERE x.period > e.m - INTERVAL 12 MONTH AND x.kg > 0)                       AS kg_12m_weighed,
        max(x.kg)  FILTER (WHERE x.period = e.m)                                                        AS kg_latest,
        count(*)   FILTER (WHERE x.period = e.m)                                                        AS rows_latest,
        count(*)   FILTER (WHERE x.period > e.m - INTERVAL 12 MONTH AND x.kg IS NULL)                   AS rows_without_weight_12m,
        sum(x.rm)  FILTER (WHERE x.period > e.m - INTERVAL 12 MONTH)                                    AS rm_12m,
        sum(x.rm)  FILTER (WHERE x.period <= e.m - INTERVAL 12 MONTH AND x.period > e.m - INTERVAL 24 MONTH) AS rm_prev_12m,
        sum(x.rm)  FILTER (WHERE x.period > e.m - INTERVAL 12 MONTH AND x.kg > 0)                       AS rm_12m_weighed,
        count(*)   FILTER (WHERE x.period > e.m - INTERVAL 12 MONTH AND x.usd IS NOT NULL AND x.rm IS NULL) AS rm_missing_12m,
        count(*)   FILTER (WHERE x.period <= e.m - INTERVAL 12 MONTH AND x.period > e.m - INTERVAL 24 MONTH
                             AND x.usd IS NOT NULL AND x.rm IS NULL)                                    AS rm_missing_prev_12m
    FROM dash_products p
    CROSS JOIN e
    LEFT JOIN x ON x.hs6 = p.hs6
    GROUP BY p.hs6
),
released AS (
    SELECT
        count(*) FILTER (WHERE r.period > e.m - INTERVAL 12 MONTH)                                     AS months_released_12m,
        count(*) FILTER (WHERE r.period <= e.m - INTERVAL 12 MONTH AND r.period > e.m - INTERVAL 24 MONTH) AS months_released_prev_12m
    FROM reporter_periods r CROSS JOIN e
    WHERE r.reporter_code = 458
)
SELECT
    a.hs6,
    strftime(e.m, '%Y-%m')                                               AS latest_month,
    round(coalesce(a.kg_12m, 0) / 1000, 3)                               AS t_12m,
    round(coalesce(a.kg_prev_12m, 0) / 1000, 3)                          AS t_prev_12m,
    round(100 * (coalesce(a.kg_12m, 0) - a.kg_prev_12m) / nullif(a.kg_prev_12m, 0), 1) AS t_change_pct,
    coalesce(a.usd_12m, 0)                                               AS usd_12m,
    coalesce(a.usd_prev_12m, 0)                                          AS usd_prev_12m,
    round(100 * (coalesce(a.usd_12m, 0) - a.usd_prev_12m) / nullif(a.usd_prev_12m, 0), 1) AS usd_change_pct,
    round(a.usd_12m_weighed / nullif(a.kg_12m_weighed, 0), 2)            AS usd_per_kg_12m,
    CASE WHEN a.rows_latest = 0 THEN 0 ELSE round(a.kg_latest / 1000, 3) END AS t_latest,
    rl.months_released_12m,
    rl.months_released_prev_12m,
    a.rows_without_weight_12m,
    CASE WHEN a.rm_missing_12m = 0 THEN round(coalesce(a.rm_12m, 0), 2) END                      AS rm_12m,
    CASE WHEN a.rm_missing_prev_12m = 0 THEN round(coalesce(a.rm_prev_12m, 0), 2) END            AS rm_prev_12m,
    CASE WHEN a.rm_missing_12m = 0 AND a.rm_missing_prev_12m = 0
         THEN round(100 * (coalesce(a.rm_12m, 0) - a.rm_prev_12m) / nullif(a.rm_prev_12m, 0), 1) END AS rm_change_pct,
    CASE WHEN a.rm_missing_12m = 0 THEN round(a.rm_12m_weighed / nullif(a.kg_12m_weighed, 0), 2) END AS rm_per_kg_12m
FROM agg a
CROSS JOIN e
CROSS JOIN released rl
JOIN dash_products p USING (hs6)
WHERE e.m IS NOT NULL
ORDER BY p.sort;

-- Top 10 destinations per window and product, with their share of the World row.
CREATE OR REPLACE TABLE dash_destinations AS
WITH x AS (
    SELECT w.win, c.hs6, c.partner_code, any_value(c.partner) AS partner,
           sum(c.net_wgt_kg) AS kg, sum(c.value_usd) AS usd,
           CASE WHEN count(c.value_usd) = count(c.value_rm) THEN sum(c.value_rm) END AS rm
    FROM comtrade_rm c
    JOIN dash_windows w ON c.period BETWEEN w.start_month AND w.end_month
    WHERE c.reporter_code = 458 AND c.flow = 'X'
    GROUP BY w.win, c.hs6, c.partner_code
),
world AS (SELECT win, hs6, kg AS world_kg FROM x WHERE partner_code = 0),
ranked AS (
    SELECT x.*, row_number() OVER (PARTITION BY win, hs6 ORDER BY kg DESC NULLS LAST, partner_code) AS rank
    FROM x WHERE partner_code <> 0
)
SELECT r.win, r.hs6, r.rank, r.partner_code, r.partner,
       round(r.kg / 1000, 3)                               AS t,
       r.usd,
       round(r.rm, 2)                                      AS rm,
       round(100 * r.kg / nullif(w.world_kg, 0), 1)        AS share_of_world_pct
FROM ranked r
LEFT JOIN world w USING (win, hs6)
WHERE r.rank <= 10
ORDER BY r.win, r.hs6, r.rank;

-- Malaysia's exports by calendar year, product and destination (partner 0 is
-- the World row). months_released says how many months of that year Malaysia
-- has released, so the latest year is partial until it reaches 12.
CREATE OR REPLACE TABLE dash_exports_yearly AS
WITH released AS (
    SELECT year(period) AS year, count(*) AS months_released
    FROM reporter_periods
    WHERE reporter_code = 458 AND period >= DATE '2019-01-01'
    GROUP BY year(period)
)
SELECT
    c.hs6, c.partner_code, any_value(c.partner)                               AS partner,
    year(c.period)                                                            AS year,
    round(sum(c.net_wgt_kg) / 1000, 3)                                        AS t,
    sum(c.value_usd)                                                          AS usd,
    round(sum(c.value_usd) FILTER (WHERE c.net_wgt_kg > 0)
          / nullif(sum(c.net_wgt_kg) FILTER (WHERE c.net_wgt_kg > 0), 0), 2)  AS usd_per_kg,
    count(*)                                                                  AS months_with_rows,
    any_value(r.months_released)                                              AS months_released,
    CASE WHEN count(c.value_usd) = count(c.value_rm)
         THEN round(sum(c.value_rm), 2) END                                   AS rm,
    CASE WHEN count(c.value_usd) = count(c.value_rm)
         THEN round(sum(c.value_rm) FILTER (WHERE c.net_wgt_kg > 0)
                    / nullif(sum(c.net_wgt_kg) FILTER (WHERE c.net_wgt_kg > 0), 0), 2) END AS rm_per_kg
FROM comtrade_rm c
LEFT JOIN released r ON r.year = year(c.period)
WHERE c.reporter_code = 458 AND c.flow = 'X'
GROUP BY c.hs6, c.partner_code, year(c.period)
ORDER BY c.hs6, c.partner_code, year;

-- Mirror check, every month: Malaysia's exports to P against P's imports from
-- Malaysia (mirror_gap), with the months mirror_gap has no row for filled in as
-- 0 when released and NULL when not. USD follows the same rule, so a partner
-- that files a value without a weight still shows up on the value side.
CREATE OR REPLACE TABLE dash_mirror_monthly AS
WITH months AS (
    SELECT unnest(generate_series(DATE '2019-01-01', (SELECT end_month FROM dash_windows WHERE win = 'all'),
                                  INTERVAL 1 MONTH))::DATE AS period
),
sources AS (
    SELECT 'comtrade' AS mirror_source, code AS partner_code FROM mirror_partners
    UNION ALL
    SELECT 'gacc', 156 WHERE EXISTS (SELECT 1 FROM gacc_periods WHERE flow = 'M')
),
released AS (
    SELECT 'comtrade' AS mirror_source, reporter_code AS partner_code, period FROM reporter_periods
    UNION ALL
    SELECT 'gacc', 156, period FROM gacc_periods WHERE flow = 'M'
)
SELECT
    s.mirror_source, s.partner_code, p.hs6, strftime(m.period, '%Y-%m') AS month,
    round(CASE WHEN g.hs6 IS NOT NULL THEN g.my_kg
               WHEN r_my.period IS NOT NULL THEN 0 END / 1000, 3)     AS my_t,
    round(CASE WHEN g.hs6 IS NOT NULL THEN g.mirror_kg
               WHEN r_mi.period IS NOT NULL THEN 0 END / 1000, 3)     AS mirror_t,
    CASE WHEN g.hs6 IS NOT NULL AND g.my_kg IS NOT NULL THEN coalesce(g.my_value_usd, 0)
         WHEN g.hs6 IS NULL AND r_my.period IS NOT NULL THEN 0 END    AS my_usd,
    CASE WHEN g.hs6 IS NOT NULL AND g.mirror_kg IS NOT NULL THEN coalesce(g.mirror_value_usd, 0)
         WHEN g.hs6 IS NULL AND r_mi.period IS NOT NULL THEN 0 END    AS mirror_usd,
    fx.usd_myr                                                        AS usd_myr
FROM sources s
CROSS JOIN dash_products p
CROSS JOIN months m
LEFT JOIN mirror_gap g ON g.mirror_source = s.mirror_source AND g.partner_code = s.partner_code
                      AND g.hs6 = p.hs6 AND g.period = m.period
LEFT JOIN reporter_periods r_my ON r_my.reporter_code = 458 AND r_my.period = m.period
LEFT JOIN released r_mi ON r_mi.mirror_source = s.mirror_source AND r_mi.partner_code = s.partner_code
                       AND r_mi.period = m.period
LEFT JOIN fx_monthly fx ON fx.period = m.period
ORDER BY s.mirror_source, s.partner_code, p.sort, m.period;

-- Mirror totals per window over the months both sides have released, in tonnes and USD
-- (exports FOB, partners' imports CIF).
CREATE OR REPLACE TABLE dash_mirror_summary AS
SELECT
    w.win, d.mirror_source, d.partner_code, mp.name AS partner, d.hs6,
    round(sum(d.my_t)     FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL), 3) AS my_t,
    round(sum(d.mirror_t) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL), 3) AS mirror_t,
    round(sum(d.mirror_t) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL)
          / nullif(sum(d.my_t) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL), 0), 3) AS mirror_to_my_ratio,
    sum(d.my_usd)     FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL)           AS my_usd,
    sum(d.mirror_usd) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL)           AS mirror_usd,
    round(sum(d.mirror_usd) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL)
          / nullif(sum(d.my_usd) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL), 0), 3) AS mirror_to_my_usd_ratio,
    CASE WHEN count(*) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL AND d.usd_myr IS NULL) = 0
         THEN round(sum(d.my_usd * d.usd_myr) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL), 2) END AS my_rm,
    CASE WHEN count(*) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL AND d.usd_myr IS NULL) = 0
         THEN round(sum(d.mirror_usd * d.usd_myr) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL), 2) END AS mirror_rm,
    count(*) FILTER (WHERE d.my_t IS NOT NULL AND d.mirror_t IS NOT NULL)                  AS months_compared,
    count(*)                                                                               AS months_in_window
FROM dash_mirror_monthly d
JOIN dash_windows w ON strptime(d.month, '%Y-%m')::DATE BETWEEN w.start_month AND w.end_month
JOIN mirror_partners mp ON mp.code = d.partner_code
GROUP BY w.win, d.mirror_source, d.partner_code, mp.name, d.hs6
ORDER BY w.win, d.hs6, my_t DESC NULLS LAST, d.mirror_source, d.partner_code;

-- Flags from mom_jumps and unit_value on the series that involve Malaysia:
-- Malaysia's exports, partners' imports from Malaysia, and GACC lines from Malaysia.
CREATE OR REPLACE TABLE dash_flags AS
WITH names AS (
    SELECT code::VARCHAR AS code, name FROM mirror_partners
    UNION ALL SELECT '458', 'Malaysia'
    UNION ALL SELECT partner_code::VARCHAR, any_value(partner) FROM comtrade
          WHERE partner_code NOT IN (SELECT code FROM mirror_partners) AND partner_code <> 458
          GROUP BY partner_code
),
mom AS (
    SELECT 'mom_jumps' AS check_table, source, reporter, flow, partner, code, period, flag,
           round(prev_kg / 1000, 3) AS prev_t, round(kg / 1000, 3) AS t, ratio,
           NULL::DOUBLE AS usd_per_kg, NULL::DOUBLE AS series_median_usd_per_kg
    FROM mom_jumps WHERE flag IS NOT NULL
),
uv AS (
    SELECT 'unit_value', source, reporter, flow, partner, code, period, flag,
           NULL, round(kg / 1000, 3), ratio_to_median, usd_per_kg, series_median_usd_per_kg
    FROM unit_value WHERE flag IN ('high', 'low')
),
f AS (SELECT * FROM mom UNION ALL SELECT * FROM uv)
SELECT
    f.check_table, f.source, strftime(f.period, '%Y-%m') AS month, left(f.code, 6) AS hs6, f.code,
    f.flow, f.reporter, coalesce(rn.name, f.reporter) AS reporter_name,
    f.partner, coalesce(pn.name, f.partner) AS partner_name,
    f.flag, f.prev_t, f.t, f.ratio, f.usd_per_kg, f.series_median_usd_per_kg
FROM f
LEFT JOIN names rn ON rn.code = f.reporter
LEFT JOIN names pn ON pn.code = f.partner AND f.source = 'comtrade'
WHERE (f.source = 'comtrade' AND (f.reporter = '458' OR (f.flow = 'M' AND f.partner = '458')))
   OR (f.source = 'gacc' AND f.flow = 'M' AND (f.partner = '马来西亚' OR lower(f.partner) LIKE '%malaysia%'))
ORDER BY f.period DESC, f.check_table, hs6, f.reporter, f.partner;

-- Revisions against the last committed data/clean/ (snapshot_diff), largest first.
CREATE OR REPLACE TABLE dash_changes AS
SELECT
    dataset, reporter, flow, partner, code, strftime(period, '%Y-%m') AS month, change,
    round(prev_kg / 1000, 3) AS prev_t, round(kg / 1000, 3) AS t, round(kg_delta / 1000, 3) AS t_delta,
    prev_value, value, value_delta
FROM snapshot_diff
WHERE (SELECT has_snapshot FROM snapshot_meta)
ORDER BY abs(coalesce(kg_delta, kg, prev_kg)) DESC NULLS LAST, dataset, reporter, flow, partner, code, period
LIMIT 200;

CREATE OR REPLACE TABLE dash_change_counts AS
SELECT dataset, change, count(*) AS n
FROM snapshot_diff
WHERE (SELECT has_snapshot FROM snapshot_meta)
GROUP BY dataset, change
ORDER BY dataset, change;

-- How far each source reaches. months_released counts from Jan 2019.
CREATE OR REPLACE TABLE dash_coverage AS
WITH reporters AS (
    SELECT 458 AS reporter_code, 'Malaysia' AS name, 'X' AS flow, 0 AS sort
    UNION ALL SELECT code, name, 'M', 1 FROM mirror_partners
)
SELECT
    'comtrade' AS source, r.reporter_code::VARCHAR AS reporter, r.name, r.flow,
    (SELECT strftime(max(period), '%Y-%m') FROM reporter_periods p WHERE p.reporter_code = r.reporter_code) AS latest_released,
    (SELECT strftime(max(period), '%Y-%m') FROM comtrade c
      WHERE c.reporter_code = r.reporter_code AND c.flow = r.flow
        AND (r.flow = 'X' OR c.partner_code = 458))                                                 AS latest_with_rows,
    (SELECT count(*) FROM reporter_periods p
      WHERE p.reporter_code = r.reporter_code AND p.period >= DATE '2019-01-01')                    AS months_released,
    r.sort
FROM reporters r
UNION ALL
SELECT 'gacc', '156', 'China (GACC CSVs)', flow,
       strftime(max(period), '%Y-%m'), strftime(max(period), '%Y-%m'), count(*), 2
FROM gacc_periods GROUP BY flow
ORDER BY sort, reporter, flow;

-- Headline status: the backtest verdict and how many flags in the last 6 months.
CREATE OR REPLACE TABLE dash_status AS
SELECT
    (SELECT verdict FROM backtest_2023_carbonate WHERE month = 'window')         AS backtest_verdict,
    (SELECT china_basis FROM backtest_2023_carbonate WHERE month = 'window')     AS backtest_china_basis,
    (SELECT months_matched FROM backtest_2023_carbonate WHERE month = 'window')  AS backtest_months_matched,
    (SELECT count(*) FROM dash_flags f, dash_windows w
      WHERE w.win = 'all' AND strptime(f.month, '%Y-%m')::DATE > w.end_month - INTERVAL 6 MONTH) AS flags_last_6m,
    (SELECT sum(n) FROM dash_change_counts)                                      AS changes_since_snapshot;

CREATE OR REPLACE TABLE dash_backtest AS
SELECT * FROM backtest_2023_carbonate;
