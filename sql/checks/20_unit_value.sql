-- Unit value (USD per kg) for every series and month, with a flag when a month's
-- unit value is far from that series' own median.
-- Series: Comtrade reporter x flow x partner x HS6, and GACC flow x partner x HS8.
-- Comtrade imports are CIF and exports FOB, so mirror unit values differ by freight.
-- GACC rows with only an RMB value get usd_per_kg NULL (no FX conversion here).

CREATE OR REPLACE TABLE unit_value AS
WITH params AS (SELECT 3.0 AS outlier_factor, 1000.0 AS min_kg),
series AS (
    SELECT 'comtrade' AS source, reporter_code::VARCHAR AS reporter, flow,
           partner_code::VARCHAR AS partner, hs6 AS code, period,
           net_wgt_kg AS kg, value_usd, net_wgt_estimated
    FROM comtrade
    UNION ALL
    SELECT 'gacc', '156', flow, partner, hs8, period, net_wgt_kg, value_usd, NULL
    FROM gacc
),
uv AS (
    SELECT *, CASE WHEN kg > 0 THEN value_usd / kg END AS usd_per_kg
    FROM series
),
med AS (
    SELECT source, reporter, flow, partner, code,
           median(usd_per_kg) FILTER (WHERE kg >= (SELECT min_kg FROM params)) AS series_median_usd_per_kg
    FROM uv GROUP BY ALL
)
SELECT
    u.source, u.reporter, u.flow, u.partner, u.code, u.period, u.kg, u.value_usd,
    round(u.usd_per_kg, 4)                                          AS usd_per_kg,
    round(m.series_median_usd_per_kg, 4)                            AS series_median_usd_per_kg,
    round(u.usd_per_kg / nullif(m.series_median_usd_per_kg, 0), 3) AS ratio_to_median,
    u.net_wgt_estimated,
    CASE WHEN u.kg IS NULL OR u.kg = 0 THEN 'no_weight'
         WHEN u.value_usd IS NULL THEN 'no_usd_value'
         WHEN u.kg < p.min_kg THEN 'small_shipment'
         WHEN u.usd_per_kg / nullif(m.series_median_usd_per_kg, 0) >= p.outlier_factor THEN 'high'
         WHEN u.usd_per_kg / nullif(m.series_median_usd_per_kg, 0) <= 1 / p.outlier_factor THEN 'low'
         ELSE 'ok' END                                              AS flag
FROM uv u
JOIN med m USING (source, reporter, flow, partner, code)
CROSS JOIN params p
ORDER BY source, reporter, flow, partner, code, period;
