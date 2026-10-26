-- Month-on-month jumps in tonnage for every series.
-- Within a series, months the reporter has released but with no row count as 0;
-- months not released are skipped (compared month is the previous released one,
-- and gap_months says how far back that was).
-- Flags: 'up'/'down' when kg moves by >= jump_factor (both months >= min_kg),
--        'appeared'/'vanished' when one side is 0 and the other >= min_kg.

CREATE OR REPLACE TABLE mom_jumps AS
WITH params AS (SELECT 3.0 AS jump_factor, 1000.0 AS min_kg),
obs AS (
    SELECT 'comtrade' AS source, reporter_code::VARCHAR AS reporter, reporter_code, flow,
           partner_code::VARCHAR AS partner, hs6 AS code, period, net_wgt_kg AS kg
    FROM comtrade
    UNION ALL
    SELECT 'gacc', '156', NULL, flow, partner, hs8, period, net_wgt_kg
    FROM gacc
),
keys AS (
    SELECT source, reporter, reporter_code, flow, partner, code,
           min(period) AS first_period, max(period) AS last_period
    FROM obs GROUP BY ALL
),
released AS (
    SELECT 'comtrade' AS source, reporter_code, NULL::VARCHAR AS flow, period FROM reporter_periods
    UNION ALL
    SELECT 'gacc', NULL, flow, period FROM gacc_periods
),
grid AS (
    -- every released month from the series' first month onward
    SELECT k.*, r.period
    FROM keys k
    JOIN released r ON r.source = k.source
                   AND (k.source = 'gacc' AND r.flow = k.flow
                        OR k.source = 'comtrade' AND r.reporter_code = k.reporter_code)
                   AND r.period >= k.first_period
),
filled AS (
    SELECT g.source, g.reporter, g.flow, g.partner, g.code, g.period,
           coalesce(o.kg, 0) AS kg, o.kg IS NULL AS no_row
    FROM grid g
    LEFT JOIN obs o USING (source, reporter, flow, partner, code, period)
),
lagged AS (
    SELECT *,
           lag(kg)     OVER w AS prev_kg,
           lag(period) OVER w AS prev_period
    FROM filled
    WINDOW w AS (PARTITION BY source, reporter, flow, partner, code ORDER BY period)
)
SELECT
    l.source, l.reporter, l.flow, l.partner, l.code, l.period, l.prev_period,
    datediff('month', l.prev_period, l.period) AS gap_months,
    l.prev_kg, l.kg, l.no_row,
    round(l.kg / nullif(l.prev_kg, 0), 3)      AS ratio,
    CASE WHEN l.prev_kg >= p.min_kg AND l.kg >= p.min_kg AND l.kg / l.prev_kg >= p.jump_factor THEN 'up'
         WHEN l.prev_kg >= p.min_kg AND l.kg >= p.min_kg AND l.prev_kg / l.kg >= p.jump_factor THEN 'down'
         WHEN l.prev_kg = 0 AND l.kg >= p.min_kg THEN 'appeared'
         WHEN l.prev_kg >= p.min_kg AND l.kg = 0 THEN 'vanished'
    END AS flag
FROM lagged l CROSS JOIN params p
WHERE l.prev_period IS NOT NULL
ORDER BY l.source, l.reporter, l.flow, l.partner, l.code, l.period;
