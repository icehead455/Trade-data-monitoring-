-- Mirror check by calendar year: Malaysia's exports to P against P's imports from
-- Malaysia (mirror_gap), summed over the months both sides have released.
-- A month both sides released with no row in mirror_gap counts as 0 on both sides,
-- so months_compared says how much of the year is covered (partial years, or a
-- partner that is behind, show fewer than 12).
-- my_world_t / my_world_usd are Malaysia's exports of the same HS6 to the World in
-- those same months, to compare a partner's figure with everything Malaysia reports.

CREATE OR REPLACE TABLE mirror_yearly AS
WITH both_released AS (
    SELECT 'comtrade' AS mirror_source, p.reporter_code AS partner_code, p.period
    FROM reporter_periods p
    JOIN reporter_periods my ON my.reporter_code = 458 AND my.period = p.period
    WHERE p.reporter_code IN (SELECT code FROM mirror_partners)
    UNION ALL
    SELECT 'gacc', 156, g.period
    FROM gacc_periods g
    JOIN reporter_periods my ON my.reporter_code = 458 AND my.period = g.period
    WHERE g.flow = 'M'
),
grid AS (
    SELECT b.mirror_source, b.partner_code, c.hs6, b.period
    FROM both_released b
    CROSS JOIN (SELECT DISTINCT hs6 FROM comtrade) c
    WHERE b.period >= DATE '2019-01-01'
),
world AS (
    SELECT hs6, period, net_wgt_kg AS kg, value_usd
    FROM comtrade
    WHERE reporter_code = 458 AND flow = 'X' AND partner_code = 0
)
SELECT
    gr.mirror_source, gr.partner_code, mp.name AS partner, gr.hs6, year(gr.period) AS year,
    count(*)                                                                 AS months_compared,
    round(sum(coalesce(g.my_kg, 0)) / 1000, 3)                               AS my_t,
    round(sum(coalesce(g.mirror_kg, 0)) / 1000, 3)                           AS mirror_t,
    round(sum(coalesce(g.mirror_kg, 0)) / nullif(sum(coalesce(g.my_kg, 0)), 0), 3) AS mirror_to_my_ratio,
    sum(coalesce(g.my_value_usd, 0))                                         AS my_usd,
    sum(coalesce(g.mirror_value_usd, 0))                                     AS mirror_usd,
    round(sum(coalesce(g.mirror_value_usd, 0)) / nullif(sum(coalesce(g.my_value_usd, 0)), 0), 3) AS mirror_to_my_usd_ratio,
    round(sum(coalesce(w.kg, 0)) / 1000, 3)                                  AS my_world_t,
    sum(coalesce(w.value_usd, 0))                                            AS my_world_usd,
    round(sum(coalesce(g.mirror_kg, 0)) / nullif(sum(coalesce(w.kg, 0)), 0), 3) AS mirror_to_my_world_ratio
FROM grid gr
JOIN mirror_partners mp ON mp.code = gr.partner_code
LEFT JOIN mirror_gap g ON g.mirror_source = gr.mirror_source AND g.partner_code = gr.partner_code
                      AND g.hs6 = gr.hs6 AND g.period = gr.period
LEFT JOIN world w ON w.hs6 = gr.hs6 AND w.period = gr.period
GROUP BY gr.mirror_source, gr.partner_code, mp.name, gr.hs6, year(gr.period)
ORDER BY gr.mirror_source, gr.partner_code, gr.hs6, year;
