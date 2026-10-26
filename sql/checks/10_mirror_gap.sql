-- Mirror gap (tonnage) by partner, HS code and month.
-- Malaysia's reported exports to P versus P's reported imports from Malaysia.
--   mirror_source = 'comtrade': P's own Comtrade filing (HS6)
--   mirror_source = 'gacc'    : China's GACC CSVs summed from HS8 to HS6
-- my_kg / mirror_kg are 0 when the reporter has released that month but filed
-- no row, NULL when the month is not released. gap_kg = mirror_kg - my_kg.
-- mirror_kg_next_month allows for shipping time.

CREATE OR REPLACE TABLE mirror_gap AS
WITH my AS (
    SELECT partner_code, hs6, period, net_wgt_kg AS kg, value_usd
    FROM comtrade
    WHERE reporter_code = 458 AND flow = 'X'
      AND partner_code IN (SELECT code FROM mirror_partners)
),
mirror AS (
    SELECT 'comtrade' AS mirror_source, reporter_code AS partner_code, hs6, period,
           net_wgt_kg AS kg, value_usd
    FROM comtrade
    WHERE flow = 'M' AND partner_code = 458
    UNION ALL
    SELECT 'gacc', 156, hs6, period, sum(net_wgt_kg), sum(value_usd)
    FROM gacc_from_malaysia
    GROUP BY hs6, period
),
spine AS (
    SELECT s.mirror_source, m.partner_code, m.hs6, m.period
    FROM my m CROSS JOIN (SELECT DISTINCT mirror_source FROM mirror) s
    WHERE s.mirror_source = 'comtrade' OR m.partner_code = 156
    UNION
    SELECT mirror_source, partner_code, hs6, period FROM mirror
),
mirror_released AS (
    SELECT 'comtrade' AS mirror_source, reporter_code AS partner_code, period FROM reporter_periods
    UNION ALL
    SELECT 'gacc', 156, period FROM gacc_periods WHERE flow = 'M'
),
joined AS (
    SELECT
        s.mirror_source, s.partner_code, p.name AS partner, s.hs6, s.period,
        CASE WHEN my.kg IS NOT NULL THEN my.kg
             WHEN rp_my.period IS NOT NULL THEN 0 END                          AS my_kg,
        CASE WHEN mi.kg IS NOT NULL THEN mi.kg
             WHEN rel.period IS NOT NULL THEN 0 END                            AS mirror_kg,
        CASE WHEN nx.kg IS NOT NULL THEN nx.kg
             WHEN rel_nx.period IS NOT NULL THEN 0 END                         AS mirror_kg_next_month,
        my.value_usd AS my_value_usd,
        mi.value_usd AS mirror_value_usd
    FROM spine s
    JOIN mirror_partners p ON p.code = s.partner_code
    LEFT JOIN my ON my.partner_code = s.partner_code AND my.hs6 = s.hs6 AND my.period = s.period
    LEFT JOIN mirror mi ON mi.mirror_source = s.mirror_source AND mi.partner_code = s.partner_code
                       AND mi.hs6 = s.hs6 AND mi.period = s.period
    LEFT JOIN mirror nx ON nx.mirror_source = s.mirror_source AND nx.partner_code = s.partner_code
                       AND nx.hs6 = s.hs6 AND nx.period = s.period + INTERVAL 1 MONTH
    LEFT JOIN reporter_periods rp_my ON rp_my.reporter_code = 458 AND rp_my.period = s.period
    LEFT JOIN mirror_released rel ON rel.mirror_source = s.mirror_source
                                 AND rel.partner_code = s.partner_code AND rel.period = s.period
    LEFT JOIN mirror_released rel_nx ON rel_nx.mirror_source = s.mirror_source
                                    AND rel_nx.partner_code = s.partner_code
                                    AND rel_nx.period = s.period + INTERVAL 1 MONTH
)
SELECT
    *,
    mirror_kg - my_kg                                         AS gap_kg,
    round((mirror_kg - my_kg) / nullif(my_kg, 0), 4)          AS gap_pct_of_my,
    round(mirror_kg / nullif(my_kg, 0), 4)                    AS mirror_to_my_ratio,
    CASE WHEN my_kg IS NULL OR mirror_kg IS NULL THEN 'not_comparable'
         WHEN my_kg = 0 AND mirror_kg = 0 THEN 'both_zero'
         WHEN my_kg = 0 THEN 'only_mirror'
         WHEN mirror_kg = 0 THEN 'only_malaysia'
         ELSE 'both' END                                      AS status
FROM joined
ORDER BY mirror_source, partner_code, hs6, period;
