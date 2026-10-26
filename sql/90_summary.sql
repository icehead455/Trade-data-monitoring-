-- Run summary: the figures printed by monitor/run.py and written to
-- reports/run_summary.csv. Each row names the check table it counts from.

CREATE OR REPLACE TABLE run_summary AS
SELECT 'rows' AS metric, 'comtrade' AS source_table, NULL AS detail, count(*)::VARCHAR AS value FROM comtrade
UNION ALL SELECT 'rows', 'gacc', NULL, count(*)::VARCHAR FROM gacc
UNION ALL SELECT 'rows', 'availability', NULL, count(*)::VARCHAR FROM availability
UNION ALL SELECT 'latest_month', 'comtrade', reporter_code::VARCHAR || ' ' || flow, strftime(max(period), '%Y-%m')
          FROM comtrade GROUP BY reporter_code, flow
UNION ALL SELECT 'latest_month', 'gacc', flow, strftime(max(period), '%Y-%m') FROM gacc GROUP BY flow
UNION ALL SELECT 'mirror_gap_status', 'mirror_gap', mirror_source || ' ' || status, count(*)::VARCHAR
          FROM mirror_gap GROUP BY mirror_source, status
UNION ALL SELECT 'unit_value_flag', 'unit_value', flag, count(*)::VARCHAR FROM unit_value GROUP BY flag
UNION ALL SELECT 'mom_jump_flag', 'mom_jumps', flag, count(*)::VARCHAR
          FROM mom_jumps WHERE flag IS NOT NULL GROUP BY flag
UNION ALL SELECT 'snapshot', 'snapshot_meta', 'has_snapshot', has_snapshot::VARCHAR FROM snapshot_meta
UNION ALL SELECT 'snapshot_diff', 'snapshot_diff', dataset || ' ' || change, count(*)::VARCHAR
          FROM snapshot_diff GROUP BY dataset, change
UNION ALL SELECT 'backtest_verdict', 'backtest_2023_carbonate', china_basis, verdict
          FROM backtest_2023_carbonate WHERE month = 'window'
ORDER BY metric, source_table, detail;
