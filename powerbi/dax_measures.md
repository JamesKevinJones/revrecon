# DAX measure catalog

The semantic model for the RevRecon report. Every measure reads the
reconciliation views, so Power BI never re-derives a business rule that SQL
already owns. The only exception is the what-if credit penalty, which exists to
vary that rule. At its default parameter values it must reproduce SQL exactly
(see **SLA Credit Policy Delta**).

## Model

### Tables

| Power BI table | Source | Grain |
| --- | --- | --- |
| `dim_customer` | `dim_customer` | Customer |
| `dim_contract` | `dim_contract` | Contract |
| `dim_date` | DAX calculated table (below) | Day |
| `fact_billing_reconciliation` | `vw_billing_reconciliation` | Contract x billing period |
| `fact_sla_breaches` | `vw_sla_breach_credits` | Breached contract-period |
| `fact_orphaned_usage` | `vw_orphaned_usage_events` | Unbilled usage event |
| `fact_invoices` | `fact_invoices` | Invoice |
| `fact_usage_events` | `fact_usage_events` | Usage event (optional, for drill-through) |

### Relationships

All relationships are single-direction, one-to-many, from dimension to fact.

| From (one) | To (many) |
| --- | --- |
| `dim_customer[customer_id]` | `customer_id` on every fact table |
| `dim_contract[contract_id]` | `contract_id` on every fact table |
| `dim_date[Date]` | `billing_period` on every fact table |

Do **not** relate `dim_contract` to `dim_customer`. Both already filter the
facts directly, and a dimension-to-dimension link creates ambiguous filter
paths. Put the tier and region slicers on `dim_customer`.

### Data types

Set these columns to **Fixed decimal number**. Floating point would introduce
cent-level drift against the SQL figures.

- `net_expected_amount`, `gross_expected_amount`, `sla_credit_amount`, `billed_amount`, `leakage_amount`
- `base_rate`, `tier_discount_rate`, `sla_uptime_target`

### Date table

Mark `dim_date` as the date table (**Table tools > Mark as date table**, on
`Date`). Sort `Month` by `Year Month Key`.

```dax
dim_date =
VAR FirstDate = DATE ( YEAR ( MIN ( fact_billing_reconciliation[billing_period] ) ), 1, 1 )
VAR LastDate  = DATE ( YEAR ( MAX ( fact_billing_reconciliation[billing_period] ) ), 12, 31 )
RETURN
    ADDCOLUMNS (
        CALENDAR ( FirstDate, LastDate ),
        "Year",           YEAR ( [Date] ),
        "Quarter",        "Q" & QUARTER ( [Date] ),
        "Month Number",   MONTH ( [Date] ),
        "Month",          FORMAT ( [Date], "mmm yyyy" ),
        "Year Month Key", YEAR ( [Date] ) * 100 + MONTH ( [Date] )
    )
```

### What-if parameters

Create these with **Modeling > New parameter > Numeric range**. Power BI
generates the table, the slider, and a `... Value` measure. The defaults
equal BR-04, so the report opens on the contractual policy.

| Parameter | Min | Max | Increment | Default | Meaning |
| --- | --- | --- | --- | --- | --- |
| `SLA Minor Credit Rate` | 0 | 0.50 | 0.01 | 0.10 | Credit when availability is below target |
| `SLA Major Credit Rate` | 0 | 0.75 | 0.01 | 0.25 | Credit when availability is at or past the major threshold |
| `SLA Major Threshold` | 0.25 | 3.00 | 0.25 | 1.00 | Points below target that count as a major breach |
| `SLA Target Adjustment` | -1.00 | 1.00 | 0.05 | 0.00 | Shift every contract's target (+ is stricter) |

Each generated value measure has this shape (the default is the second argument):

```dax
SLA Minor Credit Rate Value =
SELECTEDVALUE ( 'SLA Minor Credit Rate'[SLA Minor Credit Rate], 0.10 )
```

---

## Measures

Display folders are shown in brackets. Format strings are given for each measure.

### Revenue [01 Revenue]

```dax
Total Expected Revenue =
SUM ( fact_billing_reconciliation[net_expected_amount] )
-- Format: #,0.00
```

```dax
Total Billed Revenue =
SUM ( fact_billing_reconciliation[billed_amount] )
-- Unbilled periods have a blank billed_amount, so they add nothing.
-- Format: #,0.00
```

```dax
Gross Expected Revenue =
SUM ( fact_billing_reconciliation[gross_expected_amount] )
-- Before SLA credits. Format: #,0.00
```

### Leakage [02 Leakage]

```dax
Net Leakage Variance =
[Total Expected Revenue] - [Total Billed Revenue]
-- Positive = revenue lost (under-billed). Negative = customer overcharged.
-- Equals SUM ( fact_billing_reconciliation[leakage_amount] ).
-- Format: #,0.00;-#,0.00
```

```dax
Under-billed Leakage =
CALCULATE (
    SUM ( fact_billing_reconciliation[leakage_amount] ),
    fact_billing_reconciliation[leakage_amount] > 0
)
-- Format: #,0.00
```

```dax
Over-billed Exposure =
- CALCULATE (
    SUM ( fact_billing_reconciliation[leakage_amount] ),
    fact_billing_reconciliation[leakage_amount] < 0
)
-- Shown as a positive amount owed back to customers. Format: #,0.00
```

```dax
Gross Exposure =
[Under-billed Leakage] + [Over-billed Exposure]
-- Under- and over-billing offset each other in the net figure, which can hide
-- errors in both directions. This is the figure to manage. Format: #,0.00
```

```dax
% Leakage Exposure =
DIVIDE ( [Net Leakage Variance], [Total Expected Revenue] )
-- Format: 0.00%
```

```dax
% Gross Exposure =
DIVIDE ( [Gross Exposure], [Total Expected Revenue] )
-- Format: 0.00%
```

```dax
Unbilled Revenue =
CALCULATE (
    [Total Expected Revenue],
    fact_billing_reconciliation[exception_type] = "UNBILLED_USAGE"
)
-- Format: #,0.00
```

### Exceptions [03 Exceptions]

```dax
Exception Count =
CALCULATE (
    COUNTROWS ( fact_billing_reconciliation ),
    fact_billing_reconciliation[exception_type] <> "RECONCILED"
)
-- Format: #,0
```

```dax
Invoice Accuracy Rate =
DIVIDE (
    CALCULATE (
        COUNTROWS ( fact_billing_reconciliation ),
        fact_billing_reconciliation[exception_type] = "RECONCILED"
    ),
    CALCULATE (
        COUNTROWS ( fact_billing_reconciliation ),
        NOT ISBLANK ( fact_billing_reconciliation[invoice_id] )
    )
)
-- Reconciled invoices / issued invoices (BRD KPI). Format: 0.0%
```

```dax
Unbilled Usage Rate =
DIVIDE ( COUNTROWS ( fact_orphaned_usage ), COUNTROWS ( fact_usage_events ) )
-- Format: 0.00%
```

### SLA [04 SLA]

```dax
SLA Credits Due (Policy) =
SUM ( fact_billing_reconciliation[sla_credit_amount] )
-- The credits BR-04 requires, as calculated in SQL. Format: #,0.00
```

```dax
SLA Credit Compliance =
DIVIDE (
    CALCULATE ( COUNTROWS ( fact_sla_breaches ), fact_sla_breaches[credit_status] = "CREDIT_APPLIED" ),
    CALCULATE ( COUNTROWS ( fact_sla_breaches ), fact_sla_breaches[credit_status] <> "NOT_INVOICED" )
)
-- Breaches whose invoice applied the credit / breaches that were invoiced.
-- Format: 0.0%
```

```dax
Dynamic SLA Credit Penalty =
VAR MinorRate   = [SLA Minor Credit Rate Value]
VAR MajorRate   = [SLA Major Credit Rate Value]
VAR MajorPts    = [SLA Major Threshold Value]
VAR TargetShift = [SLA Target Adjustment Value]
RETURN
    SUMX (
        fact_billing_reconciliation,
        VAR Events = fact_billing_reconciliation[event_count]
        VAR Errors = fact_billing_reconciliation[error_events]
        VAR Target = fact_billing_reconciliation[sla_uptime_target] + TargetShift
        VAR Rate =
            -- Same cross-multiplied comparison as vw_expected_billing, so the
            -- boundary (availability exactly at target) is not a breach.
            SWITCH (
                TRUE (),
                100 * Errors >= ( 100 - Target + MajorPts ) * Events, MajorRate,
                100 * Errors > ( 100 - Target ) * Events, MinorRate,
                0
            )
        RETURN
            ROUND ( fact_billing_reconciliation[gross_expected_amount] * Rate, 2 )
    )
-- Recalculates every period's credit under the slider settings.
-- Format: #,0.00
```

```dax
SLA Credit Policy Delta =
[Dynamic SLA Credit Penalty] - [SLA Credits Due (Policy)]
-- 0.00 at default slider values. Anything else at defaults means the DAX
-- and SQL rules have drifted. Put this on the What-If page as a check.
-- Format: #,0.00;-#,0.00
```

```dax
Net Expected Revenue (What-If) =
[Gross Expected Revenue] - [Dynamic SLA Credit Penalty]
-- Format: #,0.00
```

```dax
What-If Revenue Impact =
[Net Expected Revenue (What-If)] - [Total Expected Revenue]
-- Revenue gained (+) or given up (-) by the simulated credit policy.
-- Format: #,0.00;-#,0.00
```

### Time intelligence [05 Time]

All of these require `dim_date` to be marked as the date table and the
visual to be at month granularity.

```dax
Prior Month Leakage =
CALCULATE ( [Net Leakage Variance], DATEADD ( dim_date[Date], -1, MONTH ) )
-- Format: #,0.00;-#,0.00
```

```dax
MoM Leakage Variance =
VAR CurrentLeakage = [Net Leakage Variance]
VAR PriorLeakage   = [Prior Month Leakage]
RETURN
    IF ( NOT ISBLANK ( PriorLeakage ), CurrentLeakage - PriorLeakage )
-- Blank in the first month, rather than a misleading jump from zero.
-- Format: +#,0.00;-#,0.00;0.00
```

```dax
MoM Leakage Variance % =
DIVIDE ( [MoM Leakage Variance], ABS ( [Prior Month Leakage] ) )
-- ABS keeps the sign meaningful when the prior month was over-billed (negative).
-- Format: +0.0%;-0.0%;0.0%
```

```dax
Rolling 3M Net Leakage =
CALCULATE (
    [Net Leakage Variance],
    DATESINPERIOD ( dim_date[Date], MAX ( dim_date[Date] ), -3, MONTH )
)
-- Format: #,0.00;-#,0.00
```

```dax
Leakage YTD =
TOTALYTD ( [Net Leakage Variance], dim_date[Date] )
-- Calendar year. For a fiscal year, add the year-end date, e.g. "6/30".
-- Format: #,0.00;-#,0.00
```

### Formatting helpers [99 Formatting]

```dax
Leakage Exposure Status =
VAR Pct = [% Gross Exposure]
RETURN
    SWITCH (
        TRUE (),
        ISBLANK ( Pct ), BLANK (),
        Pct < 0.005, "On target",
        Pct < 0.01,  "Watch",
        "Action required"
    )
-- Thresholds follow the BRD Section 5 targets. Drives the KPI card label.
```

```dax
Leakage Color =
IF ( [Net Leakage Variance] > 0, "#B42318", IF ( [Net Leakage Variance] < 0, "#B54708", "#667085" ) )
-- Conditional formatting (Field value): under-billed accent, over-billed
-- amber, reconciled neutral. Colours match the theme in dashboard_spec.md.
```

---

## Reconciliation checks

Before publishing, these must hold with no slicers applied (baseline dataset,
seed 42):

| Measure | Expected | Source of truth |
| --- | --- | --- |
| Total Expected Revenue | 159,591.23 | `sql/04_verify_detection.sql`, headline query |
| Total Billed Revenue | 155,083.78 | same |
| Net Leakage Variance | 4,507.45 | same |
| % Leakage Exposure | 2.82% | same |
| Exception Count | 70 | same |
| SLA Credit Policy Delta | 0.00 | by construction |
