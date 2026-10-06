# User stories

Each story traces to the BRD acceptance criteria (AC) and business rules (BR)
in [`BRD.md`](BRD.md).

| ID | As a... | I want... | So that... | Traces to |
| --- | --- | --- | --- | --- |
| US-1 | Revenue Accountant | a list of every contract-period with usage but no invoice | I can raise the missing invoices before the quarter closes | AC-1, OBJ-1 |
| US-2 | Billing Operations analyst | each mispriced invoice shown with the discount it applied next to the contracted discount | I can reissue it at the right price without re-deriving the contract | AC-2, BR-01 |
| US-3 | Customer Success manager | SLA credits calculated from telemetry every month | credits are applied before the customer has to ask | AC-3, BR-03, BR-04 |
| US-4 | Account Executive | an alert when one of my accounts was invoiced at full price in a breach month | I can contact the customer before they find the overcharge | AC-4, BR-07 |
| US-5 | Revenue Controller | rounding noise kept off the exception list | the team spends its time on real errors | AC-5, BR-05 |
| US-6 | Internal Auditor | evidence that the control finds every seeded error and no false ones | I can rely on the control without re-performing it by hand each quarter | AC-6 |
| US-7 | Finance leadership | leakage trend, month over month, by tier and region | we can see whether the fixes are working | KPIs (BRD Section 5) |
| US-8 | Data Engineer | one documented definition of each rule, in views | Power BI, Excel and ad-hoc SQL can't drift apart | OBJ-4 |

## Definition of done (all stories)

- `sql/04_verify_detection.sql` returns PASS on every row.
- The figures agree across the SQL views, the Excel workpaper Summary, and the Power BI Executive Summary.
- Any rule change is made in both `scripts/billing_rules.py` and `sql/02_reconciliation_views.sql`, and recorded in `docs/DECISIONS.md`.
