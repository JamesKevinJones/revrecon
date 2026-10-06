-- =============================================================================
-- RevRecon: 01_schema.sql
-- Star schema for revenue leakage and SLA billing reconciliation.
-- Target: MySQL 8.0.16+ (CHECK constraints enforced, CTEs/window functions in views).
--
-- DESTRUCTIVE: drops and recreates every RevRecon table. Run order:
--   01_schema.sql -> 02_reconciliation_views.sql -> 03_load_data.sql -> 04_verify_detection.sql
-- Column definitions and business meaning: docs/data_dictionary.md
-- =============================================================================

CREATE DATABASE IF NOT EXISTS revrecon
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_0900_ai_ci;

USE revrecon;

-- Child tables first so the drops never trip a foreign key.
DROP TABLE IF EXISTS audit_seeded_anomalies;
DROP TABLE IF EXISTS fact_invoices;
DROP TABLE IF EXISTS fact_usage_events;
DROP TABLE IF EXISTS dim_contract;
DROP TABLE IF EXISTS dim_customer;

-- -----------------------------------------------------------------------------
-- Dimensions
-- -----------------------------------------------------------------------------

CREATE TABLE dim_customer (
    customer_id     INT UNSIGNED    NOT NULL,
    company_name    VARCHAR(150)    NOT NULL,
    tier            ENUM('Enterprise', 'Growth', 'Starter') NOT NULL,
    region          ENUM('NA', 'EMEA', 'APAC', 'LATAM')     NOT NULL,
    signup_date     DATE            NOT NULL,
    CONSTRAINT pk_dim_customer PRIMARY KEY (customer_id),
    INDEX ix_customer_tier_region (tier, region),
    INDEX ix_customer_signup (signup_date)
) ENGINE = InnoDB COMMENT = 'One row per customer account.';

CREATE TABLE dim_contract (
    contract_id         INT UNSIGNED    NOT NULL,
    customer_id         INT UNSIGNED    NOT NULL,
    start_date          DATE            NOT NULL,
    end_date            DATE            NOT NULL,
    committed_volume    INT UNSIGNED    NOT NULL COMMENT 'Minimum billable units per monthly billing period (BR-02).',
    base_rate           DECIMAL(10, 4)  NOT NULL COMMENT 'List price per unit, before tier discount.',
    tier_discount_rate  DECIMAL(5, 4)   NOT NULL COMMENT 'Fraction off base_rate, 0.2000 = 20%.',
    sla_uptime_target   DECIMAL(5, 2)   NOT NULL COMMENT 'Monthly availability target in percent, e.g. 99.50.',
    CONSTRAINT pk_dim_contract PRIMARY KEY (contract_id),
    CONSTRAINT fk_contract_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id),
    CONSTRAINT ck_contract_term     CHECK (end_date >= start_date),
    CONSTRAINT ck_contract_rate     CHECK (base_rate > 0),
    CONSTRAINT ck_contract_discount CHECK (tier_discount_rate BETWEEN 0 AND 1),
    CONSTRAINT ck_contract_sla      CHECK (sla_uptime_target BETWEEN 90 AND 100),
    INDEX ix_contract_customer (customer_id),
    INDEX ix_contract_term (start_date, end_date)
) ENGINE = InnoDB COMMENT = 'Commercial terms. A customer can hold several contracts over time.';

-- -----------------------------------------------------------------------------
-- Facts
-- -----------------------------------------------------------------------------

CREATE TABLE fact_usage_events (
    event_id            BIGINT UNSIGNED NOT NULL,
    customer_id         INT UNSIGNED    NOT NULL,
    contract_id         INT UNSIGNED    NOT NULL,
    `timestamp`         DATETIME        NOT NULL COMMENT 'Event time, UTC.',
    units_consumed      INT UNSIGNED    NOT NULL COMMENT 'Billable units; 0 for failed calls (BR-02).',
    response_latency_ms INT UNSIGNED    NOT NULL,
    is_error            TINYINT(1)      NOT NULL DEFAULT 0,
    -- Derived month bucket so period joins can use an index instead of
    -- wrapping `timestamp` in a function on every reconciliation query.
    billing_period      DATE GENERATED ALWAYS AS
                        (DATE_SUB(DATE(`timestamp`), INTERVAL DAYOFMONTH(`timestamp`) - 1 DAY)) STORED,
    CONSTRAINT pk_fact_usage_events PRIMARY KEY (event_id),
    CONSTRAINT fk_usage_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id),
    CONSTRAINT fk_usage_contract FOREIGN KEY (contract_id) REFERENCES dim_contract (contract_id),
    CONSTRAINT ck_usage_is_error CHECK (is_error IN (0, 1)),
    INDEX ix_usage_contract_period (contract_id, billing_period),
    INDEX ix_usage_customer_time (customer_id, `timestamp`),
    INDEX ix_usage_time (`timestamp`)
) ENGINE = InnoDB COMMENT = 'One row per metered API call.';

CREATE TABLE fact_invoices (
    invoice_id      INT UNSIGNED    NOT NULL,
    customer_id     INT UNSIGNED    NOT NULL,
    contract_id     INT UNSIGNED    NOT NULL,
    billing_period  DATE            NOT NULL COMMENT 'First day of the billed calendar month.',
    billed_amount   DECIMAL(14, 2)  NOT NULL COMMENT 'Net amount invoiced, after any SLA credit.',
    invoice_status  ENUM('OPEN', 'PAID', 'OVERDUE') NOT NULL,
    CONSTRAINT pk_fact_invoices PRIMARY KEY (invoice_id),
    CONSTRAINT fk_invoice_customer FOREIGN KEY (customer_id) REFERENCES dim_customer (customer_id),
    CONSTRAINT fk_invoice_contract FOREIGN KEY (contract_id) REFERENCES dim_contract (contract_id),
    -- BR-06: one invoice per contract per billing period.
    CONSTRAINT uq_invoice_contract_period UNIQUE (contract_id, billing_period),
    CONSTRAINT ck_invoice_period_is_month_start CHECK (DAYOFMONTH(billing_period) = 1),
    CONSTRAINT ck_invoice_amount CHECK (billed_amount >= 0),
    INDEX ix_invoice_customer_period (customer_id, billing_period),
    INDEX ix_invoice_period (billing_period),
    INDEX ix_invoice_status (invoice_status)
) ENGINE = InnoDB COMMENT = 'One row per issued invoice.';

-- -----------------------------------------------------------------------------
-- Verification only: ground truth written by scripts/generate_dataset.py.
-- Not part of the star schema; production loads leave it empty.
-- -----------------------------------------------------------------------------

CREATE TABLE audit_seeded_anomalies (
    anomaly_type    ENUM('UNBILLED_USAGE', 'TIER_PRICING_VARIANCE', 'MISSED_SLA_CREDIT') NOT NULL,
    customer_id     INT UNSIGNED    NOT NULL,
    contract_id     INT UNSIGNED    NOT NULL,
    billing_period  DATE            NOT NULL,
    invoice_id      INT UNSIGNED    NULL,
    event_count     INT UNSIGNED    NOT NULL,
    expected_amount DECIMAL(14, 2)  NOT NULL,
    billed_amount   DECIMAL(14, 2)  NULL,
    leakage_amount  DECIMAL(14, 2)  NOT NULL,
    detail          VARCHAR(255)    NOT NULL,
    CONSTRAINT pk_audit_seeded_anomalies PRIMARY KEY (contract_id, billing_period)
) ENGINE = InnoDB COMMENT = 'Synthetic-data ground truth for sql/04_verify_detection.sql.';
