# Business Requirements Document: RevRecon

**Revenue Leakage & SLA Billing Reconciliation Platform**

| | |
| --- | --- |
| Document owner | Business Analysis |
| Approver | Revenue Controller |
| Version | 1.0 |
| Status | Baselined for build |
| Last updated | 2026-10-06 |

Every figure in this document labelled "baseline" comes from the synthetic
dataset in this repository (seed 42, Oct 2025 to Sep 2026). Figures labelled
"target" are proposed and need sign-off from Finance.

---

## 1. Problem statement

The company sells metered API access under contracts that combine a per-unit
price, a tier discount, a monthly volume commitment and an SLA availability
target with service credits. Usage is metered in one system. Invoices are
raised in another. Contract terms live in a third. Nobody reconciles the three
on a regular schedule.

Three failure modes go undetected as a result:

1. **Unbilled usage.** Usage is metered, but no invoice is raised for the
   period. This is lost revenue, and it is rarely recovered after quarter close.
2. **Tier pricing errors.** An invoice applies a different tier's discount from
   the one in the contract. Under-billing loses revenue. Over-billing creates
   refund liability and damages trust with the account.
3. **Missed SLA credits.** A breach month is invoiced at full price. The customer
   is overcharged, a contractual obligation is breached, and an Account
   Executive usually finds out from the customer first.

**Baseline:** 70 of 691 contract-periods (10.1%) carry an exception. That is
4,507.45 of net leakage, or 2.82% of the 159,591.23 expected revenue. Under-billing
and over-billing partly cancel out in the net figure, so gross exposure
(Section 5) is the number to manage.

## 2. Objectives

| ID | Objective |
| --- | --- |
| OBJ-1 | Detect every contract-period whose invoice does not match its contract terms, within 3 business days of month-end close. |
| OBJ-2 | Classify each exception by root cause, so it goes to the team that can fix it. |
| OBJ-3 | Calculate SLA credits automatically from usage telemetry, rather than from customer complaints. |
| OBJ-4 | Give Finance and Account Executives a single source of truth for leakage, in SQL and Power BI, with figures that agree to the cent. |

## 3. Stakeholder matrix

| Stakeholder | Role in RevRecon | Needs | Involvement | RACI |
| --- | --- | --- | --- | --- |
| **Finance: Revenue Accounting** | Owns month-end reconciliation and sign-off | Complete, auditable list of exceptions with amounts; workpaper evidence | Daily during close | **A** (accountable for sign-off) |
| **Finance: Billing Operations** | Raises and corrects invoices | Which invoices to reissue, and the correct amount | Weekly | **R** (resolves pricing and unbilled exceptions) |
| **Account Executives** | Own the customer relationship | Early warning on SLA breaches and overcharges for their accounts, before the customer raises them | Per account, on alert | **I** for pricing, **R** for SLA credit conversations |
| **Customer Success** | SLA reporting to customers | Breach history per contract | Monthly | **C** |
| **Data Engineering** | Owns pipelines, schema and views | Stable definitions, testable rules, documented grain | Build phase, then on change | **R** (build and maintain) |
| **Revenue Controller / Internal Audit** | Control owner | Evidence the control operates: re-performance, tickmarks, sign-off | Quarterly | **A** (approves BRD and control design) |

## 4. Scope

### In scope

- Monthly reconciliation of metered usage against invoices for every contract-period that has usage.
- Expected charge calculation: unit price, tier discount, volume commitment (BR-01, BR-02).
- SLA availability per contract per month, and the credit owed (BR-03, BR-04).
- Exception classification: `UNBILLED_USAGE`, `TIER_PRICING_VARIANCE`, `MISSED_SLA_CREDIT`.
- MySQL star schema and reconciliation views; Power BI semantic model and four report pages; Excel audit workpaper.
- Synthetic data generator with seeded anomalies, for testing and demonstration.

### Out of scope (this release)

- Correcting invoices in the billing system. RevRecon detects and routes exceptions; Billing Operations fixes them.
- Contract-periods with a volume commitment but **zero usage**. The expected-billing spine is driven by usage (see OQ-2).
- Partial-month proration. Contracts start on the 1st of a month (see OQ-5).
- Taxes, currency conversion, payment collection and dunning.
- Real-time detection. The control runs monthly, after close.

## 5. KPIs

| KPI | Definition | Baseline | Target |
| --- | --- | --- | --- |
| Net Leakage Variance | Expected revenue minus billed revenue | 4,507.45 | Trending to 0 |
| % Leakage Exposure | Net Leakage Variance / Total Expected Revenue | 2.82% | < 0.5% |
| Gross Exposure | Under-billed + over-billed (absolute) | 7,640.83 (4.79%): 6,074.14 under, 1,566.69 over | < 1% of expected revenue |
| Invoice Accuracy Rate | Reconciled invoices / issued invoices | 93.1% (621 / 667) | >= 99% |
| Unbilled Usage Rate | Orphaned events / all usage events | 3.02% (1,724 / 57,071) | 0% |
| SLA Credit Compliance | Credits applied / credits due (breached, invoiced periods) | 87.0% (87 / 100) | 100% |
| Time to Detect | Business days from month end to exception list | Not measured (manual) | <= 3 |

## 6. Business rules

| ID | Rule | Implemented in |
| --- | --- | --- |
| BR-01 | Unit price = `base_rate * (1 - tier_discount_rate)`, using the rates on the contract. | `vw_expected_billing`, `billing_rules.expected_charge` |
| BR-02 | Billable units for a period = `GREATEST(units_consumed, committed_volume)`. Failed calls (`is_error = 1`) carry 0 units. | same |
| BR-03 | Availability for a contract-period = `100 * (events - error events) / events`, per calendar month. A breach is availability **strictly below** `sla_uptime_target`. | `vw_expected_billing`, `billing_rules.sla_credit_pct` |
| BR-04 | SLA credit = 10% of the gross charge when availability is below target, or 25% when it is **1.00 point or more** below target. Net expected = gross - credit. | same |
| BR-05 | An invoice reconciles when it is within **0.01** of net expected. | `vw_billing_reconciliation`, `billing_rules.classify` |
| BR-06 | At most one invoice per contract per billing period. | `fact_invoices` unique key |
| BR-07 | A second or later breach on the same contract is escalated to the Account Executive. | `vw_sla_breach_credits.breach_count_to_date` |

Exception classification is ordered, and the first match wins: no invoice ->
`UNBILLED_USAGE`; credit due and invoice equals gross -> `MISSED_SLA_CREDIT`;
any other difference over 0.01 -> `TIER_PRICING_VARIANCE`.

## 7. Acceptance criteria

Each criterion is checked automatically. The **Proved by** line names the check.

```gherkin
Feature: Revenue leakage and SLA billing reconciliation

  # AC-1
  Scenario: Usage in a period with no invoice is flagged as unbilled
    Given contract 5005 recorded 165 usage events in August 2026
      And no invoice exists for contract 5005 for billing period 2026-08-01
    When the monthly reconciliation runs
    Then contract-period 5005 / 2026-08 is classified "UNBILLED_USAGE"
      And all 165 events appear in vw_orphaned_usage_events
      And the leakage amount equals the full net expected charge for the period

  # AC-2
  Scenario: An invoice priced with another tier's discount is a pricing variance
    Given a Starter contract with tier_discount_rate 0.00 and no SLA breach in the period
      And its invoice was calculated with a 0.10 discount
    When the monthly reconciliation runs
    Then the contract-period is classified "TIER_PRICING_VARIANCE"
      And implied_discount_rate shows 0.1000 against a contracted 0.0000
      And the leakage amount is positive (under-billed)

  # AC-3
  Scenario Outline: SLA credit is calculated from availability
    Given a contract with an SLA uptime target of 99.50
      And <events> usage events in the period, of which <errors> failed
    When expected billing is calculated
    Then availability is <availability> percent
      And the SLA credit rate is <credit_pct>

    Examples:
      | events | errors | availability | credit_pct |
      | 200    | 1      | 99.500       | 0.00       |
      | 200    | 2      | 99.000       | 0.10       |
      | 200    | 3      | 98.500       | 0.25       |

  # AC-4
  Scenario: A breach month invoiced at full price is a missed SLA credit
    Given a contract-period whose availability is below its SLA target
      And the credit due is 19.98
      And the invoice equals the gross charge, with no credit deducted
    When the monthly reconciliation runs
    Then the contract-period is classified "MISSED_SLA_CREDIT"
      And vw_sla_breach_credits shows credit_status "CREDIT_MISSED"
      And the leakage amount is -19.98 (customer overcharged)

  # AC-5
  Scenario: Rounding differences within tolerance reconcile
    Given a contract-period with a net expected charge of 80.00
      And an invoice for 80.01
    When the reconciliation classifies the invoice
    Then it is classified "RECONCILED"
      And it does not appear on the exception list

  # AC-6
  Scenario: Reconciliation detects exactly the seeded anomalies
    Given the synthetic dataset with its anomaly manifest loaded into audit_seeded_anomalies
    When sql/04_verify_detection.sql runs
    Then every anomaly type reports 0 missed and 0 false positives
      And detected leakage equals seeded leakage to the cent
      And every check row reads "PASS"
```

| AC | Proved by |
| --- | --- |
| AC-1 | `sql/04_verify_detection.sql` (UNBILLED_USAGE, ORPHANED_EVENTS rows) |
| AC-2 | `sql/04_verify_detection.sql` (TIER_PRICING_VARIANCE row); `billing_rules.py` self-check |
| AC-3 | `scripts/billing_rules.py` self-check (`python scripts/billing_rules.py`) |
| AC-4 | `sql/04_verify_detection.sql` (MISSED_SLA_CREDIT, SLA_CREDIT_MISSED rows) |
| AC-5 | `scripts/billing_rules.py` self-check |
| AC-6 | `sql/04_verify_detection.sql`; `scripts/build_workpaper.py` re-performance assert |

## 8. Assumptions

- A-1: Usage events are complete and deduplicated before they reach `fact_usage_events`.
- A-2: Contract terms in `dim_contract` are the signed terms. Amendments create a new contract row.
- A-3: Availability is measured as the request success rate, not as wall-clock uptime.
- A-4: Billing periods are calendar months in UTC.

## 9. Open questions

| ID | Question | Owner | Impact if unresolved |
| --- | --- | --- | --- |
| OQ-1 | The invoice record has no separate credit line, so the credit applied is inferred as gross minus billed. Can Billing add `credit_amount` to the invoice feed? | Billing Ops | A pricing error and a credit on the same invoice cannot be told apart. They are reported as `TIER_PRICING_VARIANCE`. |
| OQ-2 | Should a contract-period with a commitment but no usage be billed at the minimum? | Revenue Accounting | Those periods are not checked today. A contract with zero usage and no invoice goes undetected. |
| OQ-3 | Are over-billed amounts refunded, or credited against the next invoice? | Revenue Controller | Changes how negative leakage is reported. |
| OQ-4 | Is a request success rate an acceptable SLA measure contractually, or do contracts define time-based uptime? | Legal / Customer Success | BR-03 may need a time-based telemetry source. |
| OQ-5 | How are contracts that start mid-month prorated? | Revenue Accounting | Today all contracts start on the 1st. |

## 10. Traceability

Requirements trace to user stories in [`user_stories.md`](user_stories.md),
data definitions in [`data_dictionary.md`](data_dictionary.md), DAX in
[`../powerbi/dax_measures.md`](../powerbi/dax_measures.md) and report pages in
[`../powerbi/dashboard_spec.md`](../powerbi/dashboard_spec.md).
