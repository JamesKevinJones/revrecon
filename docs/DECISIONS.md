# Decisions

Append-only. Newest at the top. Never edit an old entry. If one stops being
true, add a new entry that supersedes it and say so.

The point is to stop a fresh agent from "fixing" something you chose
deliberately. If a choice would look wrong without context, it belongs here.

---

## 2026-10-06: Billing rules live twice, in Python and SQL, on purpose

**Context.** The generator has to know the right answer in order to seed
anomalies. The SQL views have to find them.

**Decision.** The rules are implemented in `scripts/billing_rules.py` and,
independently, in `sql/02_reconciliation_views.sql`.
`sql/04_verify_detection.sql` compares the SQL output against the generator's
manifest, and fails on any miss, false positive, or cent of difference.

**Why not the alternative.** Generating the SQL from Python, or having the
views read a Python-computed table, would make the verification circular.
Two independent implementations that agree is the evidence an auditor wants
(re-performance).

**Consequences.** A rule change must be made in both places. If one side
alone changes, `04_verify_detection.sql` goes red.

---

## 2026-10-06: The SLA breach test cross-multiplies integers

**Context.** Availability is a ratio, and a breach is availability strictly
below target. Rounded percentages put some periods on the wrong side of the
boundary. For example, 1 error in 200 events is exactly 99.50%.

**Decision.** Breach if `100 * errors > (100 - target) * events`. Major breach
if `100 * errors >= (101 - target) * events`. This is used identically in
Python, SQL and DAX. `availability_pct` is for display only.

**Why not the alternative.** Comparing `ROUND(availability, n)` to the target
breaks at the boundary, and the error depends on `div_precision_increment`.

**Consequences.** Don't "simplify" the CASE in `vw_expected_billing` to use
`availability_pct`.

---

## 2026-10-06: Money is Decimal in Python and DECIMAL in MySQL

**Context.** Float arithmetic differs from MySQL's exact DECIMAL by a cent on
some invoices. That surfaces as false `TIER_PRICING_VARIANCE` exceptions.

**Decision.** Use `decimal.Decimal` with ROUND_HALF_UP in Python (matching
MySQL `ROUND()` on positive DECIMAL values), and fixed decimal types in
Power BI.

**Consequences.** Never pass money through `float` before comparing it.
`build_workpaper.py` converts to float only when it writes display cells.

---

## 2026-10-06: Seeded anomalies are disjoint

**Context.** If one invoice had both a pricing error and a missed credit, the
classifier would have to pick one cause, and the verification counts would
become ambiguous.

**Decision.** Pricing errors are seeded only on periods with no SLA credit
due. Missed credits are seeded only on breached periods. Unbilled periods are
excluded from both.

**Consequences.** Real data can have overlapping causes. The classifier's
first-match order (BRD Section 6) and open question OQ-1 cover that case.

---

## 2026-10-06: The expected-billing spine is driven by usage

**Context.** `vw_expected_billing` enumerates the contract-periods that have
at least one usage event.

**Decision.** Accepted for this release. The generator always emits at least
5 events per active period.

**Why not the alternative.** A recursive calendar spine per contract would also
catch zero-usage periods with a commitment. But whether those should be billed
at all is an open business question (BRD OQ-2).

**Consequences.** A contract with zero usage and no invoice is not detected.
Revisit this once OQ-2 is answered.
