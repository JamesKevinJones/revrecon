-- =============================================================================
-- RevRecon: 02_reconciliation_views.sql
-- Reconciliation logic as views, so Power BI and analysts read one definition.
--
--   vw_contract_period_usage   usage rolled up to contract x billing period
--   vw_expected_billing        what each contract-period should have cost
--   vw_billing_reconciliation  (1) expected vs invoiced, classified
--   vw_sla_breach_credits      (2) SLA breaches and the credit owed
--   vw_orphaned_usage_events   (3) usage events no invoice ever covered
--
-- Business rules (docs/BRD.md, Section 6) are implemented here independently of
-- scripts/billing_rules.py; sql/04_verify_detection.sql checks they agree.
-- Sign convention: leakage_amount > 0 is revenue lost (under-billing),
-- leakage_amount < 0 is a customer overcharged (refund exposure).
-- =============================================================================

USE revrecon;

-- -----------------------------------------------------------------------------
-- Usage per contract per billing period.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_contract_period_usage AS
SELECT
    e.customer_id,
    e.contract_id,
    e.billing_period,
    COUNT(*)              AS event_count,
    SUM(e.units_consumed) AS units_consumed,
    SUM(e.is_error)       AS error_events,
    MIN(e.`timestamp`)    AS first_event_at,
    MAX(e.`timestamp`)    AS last_event_at
FROM fact_usage_events AS e
GROUP BY e.customer_id, e.contract_id, e.billing_period;

-- -----------------------------------------------------------------------------
-- Expected charge per contract-period.
--   BR-01  price per unit  = base_rate * (1 - tier_discount_rate)
--   BR-02  billable units  = GREATEST(units_consumed, committed_volume)
--   BR-03  availability    = 100 * (events - errors) / events
--   BR-04  credit          = 10% of gross below target, 25% if 1+ point below
-- The SLA comparison cross-multiplies integers so the boundary is exact:
-- 99.50% availability against a 99.50 target is not a breach.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_expected_billing AS
WITH priced AS (
    SELECT
        u.customer_id,
        u.contract_id,
        u.billing_period,
        u.event_count,
        u.units_consumed,
        u.error_events,
        c.committed_volume,
        c.base_rate,
        c.tier_discount_rate,
        c.sla_uptime_target,
        GREATEST(u.units_consumed, c.committed_volume)                     AS billable_units,
        ROUND(100 * (u.event_count - u.error_events) / u.event_count, 3)   AS availability_pct,
        CASE
            WHEN 100 * u.error_events >= (101 - c.sla_uptime_target) * u.event_count THEN 0.25
            WHEN 100 * u.error_events >  (100 - c.sla_uptime_target) * u.event_count THEN 0.10
            ELSE 0.00
        END                                                                AS sla_credit_pct
    FROM vw_contract_period_usage AS u
    JOIN dim_contract             AS c ON c.contract_id = u.contract_id
),
grossed AS (
    SELECT
        p.*,
        ROUND(p.billable_units * p.base_rate * (1 - p.tier_discount_rate), 2) AS gross_expected_amount
    FROM priced AS p
)
SELECT
    g.*,
    ROUND(g.gross_expected_amount * g.sla_credit_pct, 2)                             AS sla_credit_amount,
    g.gross_expected_amount - ROUND(g.gross_expected_amount * g.sla_credit_pct, 2)   AS net_expected_amount
FROM grossed AS g;

-- -----------------------------------------------------------------------------
-- (1) Expected tier charges vs invoiced amounts.
-- One row per contract-period with usage, invoiced or not. This is the fact
-- table Power BI reads (fact_billing_reconciliation).
--
-- exception_type, first match wins:
--   UNBILLED_USAGE         no invoice exists for the period
--   MISSED_SLA_CREDIT      credit was due but the invoice equals the gross charge
--   TIER_PRICING_VARIANCE  any other difference above the 0.01 tolerance (BR-05)
--   RECONCILED             within tolerance
-- The invoice carries no credit line, so a credit is inferred as gross minus
-- billed. See BRD open question OQ-1.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_billing_reconciliation AS
WITH matched AS (
    SELECT
        x.*,
        i.invoice_id,
        i.invoice_status,
        i.billed_amount
    FROM vw_expected_billing AS x
    LEFT JOIN fact_invoices  AS i
           ON i.contract_id    = x.contract_id
          AND i.billing_period = x.billing_period
),
classified AS (
    SELECT
        m.*,
        m.net_expected_amount - COALESCE(m.billed_amount, 0) AS leakage_amount,
        CASE
            WHEN m.invoice_id IS NULL
                THEN 'UNBILLED_USAGE'
            WHEN m.sla_credit_amount > 0
             AND ABS(m.billed_amount - m.gross_expected_amount) <= 0.01
                THEN 'MISSED_SLA_CREDIT'
            WHEN ABS(m.billed_amount - m.net_expected_amount) > 0.01
                THEN 'TIER_PRICING_VARIANCE'
            ELSE 'RECONCILED'
        END AS exception_type,
        -- The discount the invoice actually reflects; differs from
        -- tier_discount_rate on a pricing variance.
        CASE
            WHEN m.invoice_id IS NOT NULL
                THEN ROUND(1 - (m.billed_amount + m.sla_credit_amount)
                               / (m.billable_units * m.base_rate), 4)
        END AS implied_discount_rate
    FROM matched AS m
)
SELECT
    c.*,
    SUM(c.leakage_amount) OVER (
        PARTITION BY c.customer_id
        ORDER BY c.billing_period, c.contract_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                    AS cumulative_customer_leakage,
    SUM(c.leakage_amount) OVER (PARTITION BY c.billing_period) AS period_total_leakage,
    ROW_NUMBER() OVER (
        PARTITION BY c.customer_id
        ORDER BY ABS(c.leakage_amount) DESC, c.billing_period
    )                                                    AS customer_exception_rank
FROM classified AS c;

-- -----------------------------------------------------------------------------
-- (2) SLA uptime breaches per billing cycle, with the credit penalty owed and
-- whether the invoice applied it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_sla_breach_credits AS
WITH breaches AS (
    SELECT
        r.customer_id,
        r.contract_id,
        r.billing_period,
        r.invoice_id,
        r.invoice_status,
        r.event_count,
        r.error_events,
        r.availability_pct,
        r.sla_uptime_target,
        ROUND(r.sla_uptime_target - 100 * (r.event_count - r.error_events) / r.event_count, 3) AS shortfall_pts,
        r.sla_credit_pct,
        r.gross_expected_amount,
        r.sla_credit_amount                                         AS credit_due,
        CASE
            WHEN r.invoice_id IS NOT NULL
                THEN r.gross_expected_amount - r.billed_amount
        END                                                         AS credit_applied
    FROM vw_billing_reconciliation AS r
    WHERE r.sla_credit_pct > 0
)
SELECT
    b.*,
    CASE
        WHEN b.invoice_id IS NULL                       THEN 'NOT_INVOICED'
        WHEN ABS(b.credit_applied - b.credit_due) <= 0.01 THEN 'CREDIT_APPLIED'
        WHEN b.credit_applied <= 0.01                   THEN 'CREDIT_MISSED'
        ELSE 'CREDIT_MISMATCH'
    END                                                 AS credit_status,
    -- Repeat breaches on the same contract escalate to the account team (BR-07).
    COUNT(*) OVER (
        PARTITION BY b.contract_id
        ORDER BY b.billing_period
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                   AS breach_count_to_date,
    ROW_NUMBER() OVER (
        PARTITION BY b.billing_period
        ORDER BY b.shortfall_pts DESC, b.contract_id
    )                                                   AS severity_rank_in_period
FROM breaches AS b;

-- -----------------------------------------------------------------------------
-- (3) Orphaned usage: events in a contract-period that has no invoice.
-- Event grain, with window totals so a single row carries the size of the gap.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_orphaned_usage_events AS
WITH orphaned AS (
    SELECT e.*
    FROM fact_usage_events AS e
    WHERE NOT EXISTS (
        SELECT 1
        FROM fact_invoices AS i
        WHERE i.contract_id    = e.contract_id
          AND i.billing_period = e.billing_period
    )
)
SELECT
    o.event_id,
    o.customer_id,
    o.contract_id,
    o.billing_period,
    o.`timestamp`,
    o.units_consumed,
    o.is_error,
    ROW_NUMBER()            OVER w_period AS event_seq_in_period,
    COUNT(*)                OVER w_all    AS orphaned_events_in_period,
    SUM(o.units_consumed)   OVER w_all    AS orphaned_units_in_period,
    x.net_expected_amount                 AS unbilled_amount_for_period
FROM orphaned AS o
JOIN vw_expected_billing AS x
  ON x.contract_id    = o.contract_id
 AND x.billing_period = o.billing_period
WINDOW
    w_period AS (PARTITION BY o.contract_id, o.billing_period ORDER BY o.`timestamp`, o.event_id),
    w_all    AS (PARTITION BY o.contract_id, o.billing_period);
