# Dashboard specification

Four report pages for Finance and Account Executives. Measures are defined in
[`dax_measures.md`](dax_measures.md). Canvas: 16:9, 1280 x 720, with a 24 px
outer margin and a 16 px gutter on a 12-column grid.

## Design principles

- **One accent.** The palette is neutral slate plus one deliberate accent for
  revenue lost. Over-billing gets a subdued amber, and reconciled rows stay
  neutral. There is no rainbow: a chart showing exception types uses these
  three colours and grey, in the same order on every page.
- **Numbers are content.** Right-align numeric columns and use a font with
  tabular figures (Segoe UI and DIN both work). Use thousands separators and
  two decimals for money. Use no gridlines in tables, only light row dividers.
- **Sign is meaning.** Positive leakage means revenue lost, and negative means
  the customer was overcharged. Every leakage visual has a subtitle that says so.
- **Axis titles say what and when**, for example "Net leakage by billing month,
  Oct 2025 to Sep 2026", not "billing_period".
- **Design the states**, not just the happy path. See the states table on each page.

### Theme tokens

| Token | Hex | Use |
| --- | --- | --- |
| `ink` | `#101828` | Titles, KPI values |
| `muted` | `#667085` | Labels, axis text, reconciled series |
| `rule` | `#EAECF0` | Row dividers, card borders |
| `surface` | `#FFFFFF` | Canvas |
| `panel` | `#F9FAFB` | Card background |
| `accent-loss` | `#B42318` | Under-billed leakage, unbilled usage |
| `accent-over` | `#B54708` | Over-billed exposure, missed SLA credit |
| `accent-ok` | `#067647` | "On target" status only |

Import as a report theme (**View > Themes > Browse**):

```json
{
  "name": "RevRecon",
  "dataColors": ["#B42318", "#B54708", "#475467", "#98A2B3", "#067647"],
  "background": "#FFFFFF",
  "foreground": "#101828",
  "tableAccent": "#475467",
  "textClasses": {
    "title": { "fontFace": "Segoe UI Semibold", "fontSize": 14, "color": "#101828" },
    "label": { "fontFace": "Segoe UI", "fontSize": 10, "color": "#667085" },
    "callout": { "fontFace": "Segoe UI Semibold", "fontSize": 28, "color": "#101828" }
  }
}
```

### Shared elements (every page)

- **Header row** (full width, 48 px): the page title on the left. On the right:
  "Data as of {latest billing_period} | Refreshed {refresh time}", driven by a
  measure on `MAX(dim_date[Date])` with data and on the dataset refresh time.
  Readers need to know how stale the figures are.
- **Slicer rail** (top, 40 px): Billing month (range), Tier, Region, Exception
  type. Sync it across pages with **View > Sync slicers**.
- **Reset** bookmark button that clears all slicers.

---

## Page 1: Executive Summary

**Audience:** Revenue Controller, Finance leadership. **Question:** How much
are we leaking, is it getting better, and where is it?

```
+--------------------------------------------------------------------------+
| Executive Summary                       Data as of Sep 2026 | Refreshed  |
| [Month range] [Tier] [Region] [Exception type]                  [Reset]  |
+-----------+-----------+-----------+-----------+-----------+--------------+
| Expected  | Billed    | Net       | % Leakage | Gross     | Invoice      |
| Revenue   | Revenue   | Leakage   | Exposure  | Exposure  | Accuracy     |
+-----------+-----------+-----------+-----------+-----------+--------------+
| Net leakage by billing month (columns)   | Leakage by exception type     |
| + Prior Month Leakage (line)             | (bar: under vs over, stacked) |
|                                          |                               |
+------------------------------------------+-------------------------------+
| Top 10 accounts by gross exposure (table)                                |
+--------------------------------------------------------------------------+
```

| Visual | Fields | Notes |
| --- | --- | --- |
| 6 KPI cards | Total Expected Revenue, Total Billed Revenue, Net Leakage Variance, % Leakage Exposure, Gross Exposure, Invoice Accuracy Rate | The Net Leakage card shows **MoM Leakage Variance** as its reference label. The Gross Exposure card is labelled with **Leakage Exposure Status**. Value colour comes from **Leakage Color**. |
| Combo chart | X: `dim_date[Month]`. Columns: Net Leakage Variance. Line: Prior Month Leakage | Subtitle: "Positive = revenue lost; negative = customers overcharged." Tooltip: Under-billed, Over-billed, Exception Count, MoM %. |
| Stacked bar | Axis: `exception_type` (excluding RECONCILED). Values: Under-billed Leakage, Over-billed Exposure | Shows that tier pricing errors run in both directions and partly cancel in the net figure. |
| Table | `dim_customer[company_name]`, tier, region, Gross Exposure, Net Leakage Variance, Exception Count | Top N = 10 by Gross Exposure. A row click drills through to the Account Deep-Dive. |

**States**

| State | What the reader sees |
| --- | --- |
| No exceptions in the filter | The cards show 0.00, and the chart is replaced by the text "Every contract-period in this selection reconciled." It is not an empty axis. |
| First month in range | MoM shows blank, not a jump from zero. |
| Data older than 35 days | The header "Data as of" turns `accent-over` and adds "Stale". |

---

## Page 2: Account Deep-Dive

**Audience:** Account Executives, Billing Ops. **Question:** What exactly went
wrong on this account, and what is the fix?

Drill-through target. Drill-through fields: `dim_customer[customer_id]`, `dim_contract[contract_id]`.

```
+--------------------------------------------------------------------------+
| < Back   Account: {company_name}   Tier | Region | Contract | Term       |
+-----------+-----------+-----------+-----------+--------------------------+
| Expected  | Billed    | Net       | SLA       | Breach count to date     |
|           |           | Leakage   | Compliance|                          |
+-----------+-----------+-----------+-----------+--------------------------+
| Expected vs billed by month (clustered columns) + cumulative leakage    |
| (line, secondary axis)                                                   |
+------------------------------------------+-------------------------------+
| Exception ledger (table)                 | Availability vs target        |
|                                          | (line + constant target line) |
+------------------------------------------+-------------------------------+
```

| Visual | Fields | Notes |
| --- | --- | --- |
| Header card | company_name, tier, region, contract_id, start_date to end_date, committed_volume, base_rate, tier_discount_rate, sla_uptime_target | It shows the contract terms, so the reader doesn't need to open the CRM. |
| Clustered column + line | X: month. Columns: Total Expected Revenue, Total Billed Revenue. Line: `cumulative_customer_leakage` (max) | The gap between the columns is the leakage. The line shows whether it is compounding. |
| Exception ledger | billing_period, exception_type, net_expected_amount, billed_amount, leakage_amount, tier_discount_rate, implied_discount_rate, invoice_id, invoice_status | Filter: exception_type <> RECONCILED. Sort: `customer_exception_rank`. Discount columns sit side by side so a pricing error is obvious at a glance. |
| Line chart | X: month. Y: availability_pct (average). Constant line: sla_uptime_target | Breach months are marked with `accent-over`, from `fact_sla_breaches`. |

**States**

| State | What the reader sees |
| --- | --- |
| Account fully reconciled | The ledger shows the text "No exceptions for this account in the selected months." |
| Opened without drill-through | A full-page card reads "Open an account from the Executive Summary or Root-Cause pages (right-click > Drill through)." |
| Breach not yet invoiced | Ledger status shows `NOT_INVOICED`, from `fact_sla_breaches[credit_status]`. |

---

## Page 3: Root-Cause Decomposition

**Audience:** Revenue Accounting, Data Engineering. **Question:** Which
combination of factors drives the leakage?

```
+--------------------------------------------------------------------------+
| Root-Cause Decomposition                                                 |
+--------------------------------------------------------------------------+
| Decomposition tree: Gross Exposure                                       |
|   -> exception_type -> tier -> region -> company_name -> billing month   |
|                                                                          |
+------------------------------------+-------------------------------------+
| Key influencers: exception_type    | Exceptions by tier x exception type |
| (Analyze: "is TIER_PRICING_...")   | (matrix with data bars)             |
+------------------------------------+-------------------------------------+
```

| Visual | Fields | Notes |
| --- | --- | --- |
| Decomposition tree | Analyze: **Gross Exposure**. Explain by: `exception_type`, `dim_customer[tier]`, `dim_customer[region]`, `dim_customer[company_name]`, `dim_date[Month]` | Default expansion: exception_type, then High value. Analysts can use AI splits, but the default path is fixed so the page tells the same story on every open. Gross is used rather than net, so offsetting errors don't hide a branch. |
| Key influencers | Analyze: `exception_type`. Explain by: tier, region, committed_volume, base_rate, availability_pct | Answers questions like "What makes a pricing variance more likely?" |
| Matrix | Rows: tier. Columns: exception_type. Values: Exception Count, Gross Exposure | Data bars in `accent-loss`. The total row and column are on. |

**States**

| State | What the reader sees |
| --- | --- |
| Filter leaves under 10 exceptions | Key influencers is hidden behind a card reading "Too few exceptions in this selection for influencer analysis (needs 10+)." The tree stays. |

---

## Page 4: What-If Parameter Analysis

**Audience:** Revenue Controller, Legal, Sales leadership. **Question:** What
would a different SLA credit policy cost or save?

```
+--------------------------------------------------------------------------+
| What-If: SLA credit policy                                               |
+-------------------+------------------------------------------------------+
| Minor credit rate | Policy check: SLA Credit Policy Delta = 0.00  [OK]   |
| [====o-------]    +-----------+-----------+-----------+------------------+
| Major credit rate | Credits   | Credits   | Revenue   | Net expected     |
| [======o-----]    | (policy)  | (what-if) | impact    | (what-if)        |
| Major threshold   +-----------+-----------+-----------+------------------+
| [===o--------]    | Credits by month: policy vs what-if (line)           |
| Target adjustment |                                                      |
| [------o-----]    +------------------------------------------------------+
|                   | Credits by tier: policy vs what-if (clustered bar)   |
+-------------------+------------------------------------------------------+
```

| Visual | Fields | Notes |
| --- | --- | --- |
| 4 slider slicers | The four what-if parameters | Show each slider's current value and its default in the label, e.g. "Minor credit rate: 12% (policy 10%)". |
| Policy check card | SLA Credit Policy Delta | At default sliders it must read 0.00, coloured `accent-ok`. Any other value at defaults means DAX and SQL have drifted, and the card says so. |
| 4 KPI cards | SLA Credits Due (Policy), Dynamic SLA Credit Penalty, What-If Revenue Impact, Net Expected Revenue (What-If) | |
| Line chart | X: month. Lines: SLA Credits Due (Policy), Dynamic SLA Credit Penalty | Policy line in `muted`, what-if line in `accent-over`. |
| Clustered bar | Axis: tier. Values: the same two measures | Shows which tier a policy change hits hardest. |

**States**

| State | What the reader sees |
| --- | --- |
| Sliders at defaults | The policy check reads "Matches contract policy (BR-04)". |
| Minor rate above major rate | A warning card reads "Minor credit is higher than major. Check the sliders." The calculation still runs. |

---

## Accessibility

- Every visual has alt text that states its conclusion, not its type. Pattern:
  "Net leakage peaked in {month} at {amount}, driven by {exception type}." Fill the
  values in from the published data.
- Colour is never the only signal. Exception types are also labelled, and
  status cards carry text ("On target", "Watch", "Action required").
- Tab order runs left to right, top to bottom. Set it in **View > Selection pane > Tab order**.
- The contrast ratio is at least 4.5:1 for all text on `surface` and `panel`.

## Publishing checklist

1. With no slicers applied, the cards match the reconciliation checks in `dax_measures.md`.
2. The SLA Credit Policy Delta is 0.00 at default sliders.
3. Drill-through from both the Executive Summary table and the decomposition tree opens the Account Deep-Dive.
4. Each "States" row above has been checked by filtering until it appears.
