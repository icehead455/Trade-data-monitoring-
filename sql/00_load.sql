-- Load clean Parquet tables and the previous committed snapshot into DuckDB.
-- Paths are relative to the repo root (monitor/build_db.py runs these files from there).
-- Every check in sql/checks/ reads only the tables created here.

CREATE OR REPLACE TABLE comtrade      AS SELECT * REPLACE (period::DATE AS period) FROM read_parquet('data/clean/comtrade.parquet');
CREATE OR REPLACE TABLE availability  AS SELECT * REPLACE (period::DATE AS period) FROM read_parquet('data/clean/availability.parquet');
CREATE OR REPLACE TABLE gacc          AS SELECT * REPLACE (period::DATE AS period) FROM read_parquet('data/clean/gacc.parquet');
CREATE OR REPLACE TABLE fx            AS SELECT * REPLACE (date::DATE AS date) FROM read_parquet('data/clean/fx.parquet');

-- build/prev/ holds data/clean/*.parquet as of git HEAD (empty tables if never committed).
CREATE OR REPLACE TABLE prev_comtrade AS SELECT * REPLACE (period::DATE AS period) FROM read_parquet('build/prev/comtrade.parquet');
CREATE OR REPLACE TABLE prev_gacc     AS SELECT * REPLACE (period::DATE AS period) FROM read_parquet('build/prev/gacc.parquet');
CREATE OR REPLACE TABLE snapshot_meta AS SELECT * FROM read_csv('build/prev/snapshot_meta.csv', header = true,
    columns = {'has_snapshot': 'BOOLEAN', 'commit': 'VARCHAR'});

-- Must match monitor/config.py MIRROR_REPORTERS (tests/test_pipeline.py checks this).
CREATE OR REPLACE TABLE mirror_partners (code INTEGER, name VARCHAR);
INSERT INTO mirror_partners VALUES
    (156, 'China'), (344, 'Hong Kong'), (392, 'Japan'), (410, 'South Korea'),
    (764, 'Thailand'), (704, 'Vietnam'), (702, 'Singapore'), (842, 'United States');

-- Months for which a reporter's data is out. A reporter counts as having released
-- a month if Comtrade's availability endpoint says so, or if we hold any row for it.
-- In a released month a missing row means zero trade; otherwise it is unknown (NULL).
CREATE OR REPLACE TABLE reporter_periods AS
SELECT reporter_code, period FROM availability
UNION
SELECT DISTINCT reporter_code, period FROM comtrade;

-- GACC: months covered by the China CSVs, per flow. Only as complete as the
-- exports dropped into data/inbox/china/.
CREATE OR REPLACE TABLE gacc_periods AS
SELECT DISTINCT flow, period FROM gacc;

CREATE OR REPLACE TABLE gacc_from_malaysia AS
SELECT * FROM gacc
WHERE flow = 'M' AND (partner = '马来西亚' OR lower(partner) LIKE '%malaysia%');

-- Bank Negara's noon (session 1200) USD/MYR middle rate, averaged over the days it
-- was published in each month. Ringgit figures convert each month's USD at this rate.
CREATE OR REPLACE TABLE fx_monthly AS
SELECT date_trunc('month', date)::DATE AS period, avg(middle_rate) AS usd_myr, count(*) AS days
FROM fx
WHERE session = '1200' AND middle_rate IS NOT NULL
GROUP BY 1;
