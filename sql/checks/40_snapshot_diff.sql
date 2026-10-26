-- Diff of this run's clean tables against data/clean/*.parquet at git HEAD.
-- One row per key that was added, removed, or whose kg / USD value changed
-- (Comtrade revisions, new months, new GACC files). Empty if nothing changed;
-- check snapshot_meta.has_snapshot to tell "no change" from "no snapshot yet".

CREATE OR REPLACE TABLE snapshot_diff AS
WITH cur AS (
    SELECT 'comtrade' AS dataset, reporter_code::VARCHAR AS reporter, flow,
           partner_code::VARCHAR AS partner, hs6 AS code, period, net_wgt_kg AS kg, value_usd
    FROM comtrade
    UNION ALL
    SELECT 'gacc', '156', flow, partner, hs8, period, net_wgt_kg, coalesce(value_usd, value_cny)
    FROM gacc
),
prev AS (
    SELECT 'comtrade' AS dataset, reporter_code::VARCHAR AS reporter, flow,
           partner_code::VARCHAR AS partner, hs6 AS code, period, net_wgt_kg AS kg, value_usd
    FROM prev_comtrade
    UNION ALL
    SELECT 'gacc', '156', flow, partner, hs8, period, net_wgt_kg, coalesce(value_usd, value_cny)
    FROM prev_gacc
)
SELECT
    coalesce(c.dataset, p.dataset)   AS dataset,
    coalesce(c.reporter, p.reporter) AS reporter,
    coalesce(c.flow, p.flow)         AS flow,
    coalesce(c.partner, p.partner)   AS partner,
    coalesce(c.code, p.code)         AS code,
    coalesce(c.period, p.period)     AS period,
    CASE WHEN p.dataset IS NULL THEN 'added'
         WHEN c.dataset IS NULL THEN 'removed'
         ELSE 'changed' END          AS change,
    p.kg AS prev_kg, c.kg AS kg, c.kg - p.kg AS kg_delta,
    p.value_usd AS prev_value, c.value_usd AS value, c.value_usd - p.value_usd AS value_delta,
    (SELECT "commit" FROM snapshot_meta) AS snapshot_commit
FROM cur c
FULL OUTER JOIN prev p
  ON c.dataset = p.dataset AND c.reporter = p.reporter AND c.flow = p.flow
 AND c.partner = p.partner AND c.code = p.code AND c.period = p.period
WHERE p.dataset IS NULL OR c.dataset IS NULL
   OR c.kg IS DISTINCT FROM p.kg OR c.value_usd IS DISTINCT FROM p.value_usd
ORDER BY dataset, reporter, flow, partner, code, period;
