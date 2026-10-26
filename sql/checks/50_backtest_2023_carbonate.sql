-- Backtest: Feb-Apr 2023, rare earth carbonate Malaysia -> China should appear
-- in both sources, allowing China's side to land one month later.
--
-- Malaysia side: Comtrade, reporter 458, exports to 156, HS 284690. Comtrade is
--   HS6 only, so carbonate cannot be separated from other RE compounds here.
-- China side (preferred): GACC imports from Malaysia, HS8 lines under 2846 whose
--   description contains 碳酸 / "carbonate".
-- China side (fallback): Comtrade, reporter 156, imports from 458, HS 284690
--   (HS6 proxy, used only when GACC does not cover Feb-May 2023).
-- NULL = month not released / not covered; 0 = released, nothing filed.
--
-- One row per month plus a final 'window' row with the verdict:
--   PASS     Malaysia > 0 in some month of Feb-Apr AND China > 0 in some month of Feb-May
--   FAIL     at least one side is 0 across its whole window
--   NO_DATA  a side's window is not fully released / covered
-- months_matched counts months m where Malaysia(m) > 0 and China(m or m+1) > 0.

CREATE OR REPLACE TABLE backtest_2023_carbonate AS
WITH months AS (
    SELECT unnest([DATE '2023-02-01', DATE '2023-03-01', DATE '2023-04-01']) AS period
),
china_months AS (
    SELECT unnest([DATE '2023-02-01', DATE '2023-03-01', DATE '2023-04-01', DATE '2023-05-01']) AS period
),
my_side AS (
    SELECT m.period,
           CASE WHEN c.net_wgt_kg IS NOT NULL THEN c.net_wgt_kg
                WHEN r.period IS NOT NULL THEN 0 END AS kg
    FROM months m
    LEFT JOIN comtrade c ON c.reporter_code = 458 AND c.flow = 'X' AND c.partner_code = 156
                        AND c.hs6 = '284690' AND c.period = m.period
    LEFT JOIN reporter_periods r ON r.reporter_code = 458 AND r.period = m.period
),
gacc_carbonate AS (
    SELECT period, sum(net_wgt_kg) AS kg
    FROM gacc_from_malaysia
    WHERE hs8 LIKE '2846%' AND (description LIKE '%碳酸%' OR lower(description) LIKE '%carbonate%')
    GROUP BY period
),
cn_gacc AS (
    SELECT m.period,
           CASE WHEN g.kg IS NOT NULL THEN g.kg
                WHEN gp.period IS NOT NULL THEN 0 END AS kg
    FROM china_months m
    LEFT JOIN gacc_carbonate g USING (period)
    LEFT JOIN gacc_periods gp ON gp.flow = 'M' AND gp.period = m.period
),
cn_comtrade AS (
    SELECT m.period,
           CASE WHEN c.net_wgt_kg IS NOT NULL THEN c.net_wgt_kg
                WHEN r.period IS NOT NULL THEN 0 END AS kg
    FROM china_months m
    LEFT JOIN comtrade c ON c.reporter_code = 156 AND c.flow = 'M' AND c.partner_code = 458
                        AND c.hs6 = '284690' AND c.period = m.period
    LEFT JOIN reporter_periods r ON r.reporter_code = 156 AND r.period = m.period
),
basis AS (
    SELECT CASE WHEN count(kg) = 4 THEN 'gacc_hs8_carbonate'
                ELSE 'comtrade_hs6_284690_proxy' END AS china_basis
    FROM cn_gacc
),
cn AS (
    SELECT period, CASE WHEN (SELECT china_basis FROM basis) = 'gacc_hs8_carbonate'
                        THEN g.kg ELSE c.kg END AS kg
    FROM cn_gacc g JOIN cn_comtrade c USING (period)
),
per_month AS (
    SELECT
        strftime(m.period, '%Y-%m')                        AS month,
        my.kg                                              AS malaysia_export_kg,
        cn0.kg                                             AS china_import_kg_same_month,
        cn1.kg                                             AS china_import_kg_next_month,
        g0.kg                                              AS gacc_carbonate_kg_same_month,
        g1.kg                                              AS gacc_carbonate_kg_next_month,
        c0.kg                                              AS comtrade_china_284690_kg_same_month,
        c1.kg                                              AS comtrade_china_284690_kg_next_month,
        (my.kg > 0 AND (cn0.kg > 0 OR cn1.kg > 0))         AS matched
    FROM months m
    JOIN my_side my USING (period)
    JOIN cn cn0 ON cn0.period = m.period
    JOIN cn cn1 ON cn1.period = m.period + INTERVAL 1 MONTH
    JOIN cn_gacc g0 ON g0.period = m.period
    JOIN cn_gacc g1 ON g1.period = m.period + INTERVAL 1 MONTH
    JOIN cn_comtrade c0 ON c0.period = m.period
    JOIN cn_comtrade c1 ON c1.period = m.period + INTERVAL 1 MONTH
),
verdict AS (
    SELECT CASE
        WHEN (SELECT count(kg) FROM my_side) < 3 OR (SELECT count(kg) FROM cn) < 4 THEN 'NO_DATA'
        WHEN (SELECT max(kg) FROM my_side) > 0 AND (SELECT max(kg) FROM cn) > 0 THEN 'PASS'
        ELSE 'FAIL' END AS verdict
)
SELECT p.*, NULL::VARCHAR AS verdict, (SELECT china_basis FROM basis) AS china_basis,
       NULL::INTEGER AS months_matched
FROM per_month p
UNION ALL
SELECT 'window', (SELECT sum(kg) FROM my_side), NULL, NULL,
       (SELECT sum(kg) FROM cn_gacc), NULL, (SELECT sum(kg) FROM cn_comtrade), NULL,
       NULL, (SELECT verdict FROM verdict), (SELECT china_basis FROM basis),
       (SELECT count(*) FILTER (WHERE matched) FROM per_month)::INTEGER
ORDER BY month;
