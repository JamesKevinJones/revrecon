-- =============================================================================
-- RevRecon: 04_verify_detection.sql
-- Proves the reconciliation views find exactly the anomalies the generator
-- seeded: no misses, no false positives, and the same money.
-- Every row of the final result should read PASS.
-- =============================================================================

USE revrecon;

WITH detected AS (
    SELECT exception_type AS anomaly_type, contract_id, billing_period, leakage_amount
    FROM vw_billing_reconciliation
    WHERE exception_type <> 'RECONCILED'
),
seeded AS (
    SELECT anomaly_type, contract_id, billing_period, leakage_amount
    FROM audit_seeded_anomalies
),
-- MySQL has no FULL OUTER JOIN: seeded rows (matched or missed) plus
-- detected rows nobody seeded.
compared AS (
    SELECT s.anomaly_type, 1 AS is_seeded, (d.contract_id IS NOT NULL) AS is_detected,
           s.leakage_amount AS seeded_leakage, d.leakage_amount AS detected_leakage
    FROM seeded AS s
    LEFT JOIN detected AS d
           ON d.anomaly_type   = s.anomaly_type
          AND d.contract_id    = s.contract_id
          AND d.billing_period = s.billing_period
    UNION ALL
    SELECT d.anomaly_type, 0, 1, NULL, d.leakage_amount
    FROM detected AS d
    WHERE NOT EXISTS (
        SELECT 1 FROM seeded AS s
        WHERE s.anomaly_type   = d.anomaly_type
          AND s.contract_id    = d.contract_id
          AND s.billing_period = d.billing_period
    )
),
by_type AS (
    SELECT
        anomaly_type                                    AS check_name,
        SUM(is_seeded)                                  AS seeded,
        SUM(is_detected)                                AS detected,
        SUM(is_seeded AND NOT is_detected)              AS missed,
        SUM(is_detected AND NOT is_seeded)              AS false_positives,
        COALESCE(SUM(seeded_leakage), 0)                AS seeded_leakage,
        COALESCE(SUM(detected_leakage), 0)              AS detected_leakage
    FROM compared
    GROUP BY anomaly_type
),
orphan_check AS (
    SELECT
        'ORPHANED_EVENTS'                                              AS check_name,
        (SELECT SUM(event_count) FROM audit_seeded_anomalies
          WHERE anomaly_type = 'UNBILLED_USAGE')                       AS seeded,
        (SELECT COUNT(*) FROM vw_orphaned_usage_events)                AS detected
),
sla_check AS (
    SELECT
        'SLA_CREDIT_MISSED'                                            AS check_name,
        (SELECT COUNT(*) FROM audit_seeded_anomalies
          WHERE anomaly_type = 'MISSED_SLA_CREDIT')                    AS seeded,
        (SELECT COUNT(*) FROM vw_sla_breach_credits
          WHERE credit_status = 'CREDIT_MISSED')                       AS detected
)
SELECT check_name, seeded, detected, missed, false_positives, seeded_leakage, detected_leakage,
       CASE WHEN missed = 0 AND false_positives = 0 AND seeded_leakage = detected_leakage
            THEN 'PASS' ELSE 'FAIL' END AS result
FROM by_type
UNION ALL
SELECT check_name, seeded, detected, NULL, NULL, NULL, NULL,
       CASE WHEN seeded = detected THEN 'PASS' ELSE 'FAIL' END
FROM orphan_check
UNION ALL
SELECT check_name, seeded, detected, NULL, NULL, NULL, NULL,
       CASE WHEN seeded = detected THEN 'PASS' ELSE 'FAIL' END
FROM sla_check
ORDER BY check_name;

-- Headline numbers for the README / executive summary.
SELECT
    COUNT(*)                                                    AS contract_periods,
    SUM(exception_type <> 'RECONCILED')                         AS exceptions,
    SUM(net_expected_amount)                                    AS total_expected_revenue,
    SUM(COALESCE(billed_amount, 0))                             AS total_billed_revenue,
    SUM(leakage_amount)                                         AS net_leakage_variance,
    ROUND(100 * SUM(leakage_amount) / SUM(net_expected_amount), 2) AS pct_leakage_exposure
FROM vw_billing_reconciliation;
