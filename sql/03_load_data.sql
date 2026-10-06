-- =============================================================================
-- RevRecon: 03_load_data.sql
-- Loads the CSVs written by scripts/generate_dataset.py.
--
-- Run from the repository root (paths are relative to the client's working
-- directory), with local_infile enabled on both client and server:
--   mysql --local-infile=1 -u <user> -p < sql/03_load_data.sql
-- If the server refuses with error 3948, an admin runs:
--   SET GLOBAL local_infile = 1;
-- Reloading is safe: every table is emptied first.
-- =============================================================================

USE revrecon;

SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE audit_seeded_anomalies;
TRUNCATE TABLE fact_invoices;
TRUNCATE TABLE fact_usage_events;
TRUNCATE TABLE dim_contract;
TRUNCATE TABLE dim_customer;
SET FOREIGN_KEY_CHECKS = 1;

LOAD DATA LOCAL INFILE 'data/dim_customer.csv'
INTO TABLE dim_customer
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(customer_id, company_name, tier, region, signup_date);

LOAD DATA LOCAL INFILE 'data/dim_contract.csv'
INTO TABLE dim_contract
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(contract_id, customer_id, start_date, end_date, committed_volume,
 base_rate, tier_discount_rate, sla_uptime_target);

-- billing_period is a generated column, so it is left out of the column list.
LOAD DATA LOCAL INFILE 'data/fact_usage_events.csv'
INTO TABLE fact_usage_events
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(event_id, customer_id, contract_id, `timestamp`, units_consumed,
 response_latency_ms, is_error);

LOAD DATA LOCAL INFILE 'data/fact_invoices.csv'
INTO TABLE fact_invoices
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(invoice_id, customer_id, contract_id, billing_period, billed_amount, invoice_status);

LOAD DATA LOCAL INFILE 'data/anomaly_manifest.csv'
INTO TABLE audit_seeded_anomalies
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(anomaly_type, customer_id, contract_id, billing_period, invoice_id,
 event_count, expected_amount, billed_amount, leakage_amount, detail);

SELECT 'dim_customer' AS table_name, COUNT(*) AS row_count FROM dim_customer
UNION ALL SELECT 'dim_contract',           COUNT(*) FROM dim_contract
UNION ALL SELECT 'fact_usage_events',      COUNT(*) FROM fact_usage_events
UNION ALL SELECT 'fact_invoices',          COUNT(*) FROM fact_invoices
UNION ALL SELECT 'audit_seeded_anomalies', COUNT(*) FROM audit_seeded_anomalies;
