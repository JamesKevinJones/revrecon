# RevRecon

The canonical context file. Claude Code, Antigravity (`agy`) and Codex all read
this, directly or by import. Durable project knowledge goes here, and
session-to-session status goes in `docs/STATE.md`.

## What this is

A Business Analyst portfolio project that reconciles metered API usage against
invoices and contract terms, to find revenue leakage. That covers unbilled
usage, wrong tier pricing, and SLA credits that were owed but never applied. It
has a requirements pack (BRD, data dictionary, user stories), a MySQL star
schema with reconciliation views, a synthetic data generator that seeds known
anomalies, a Power BI semantic model spec, and an Excel audit workpaper. All of
the data is synthetic.

## Stack

- Python 3.12+ (developed on 3.14) with pandas, Faker and openpyxl. See `scripts/requirements.txt`. Use a `.venv` at the repo root.
- MySQL **8.0.16+**: CHECK constraints must be enforced, and views need CTEs and window functions. Verified on 8.4.
- Power BI Desktop. Specs only; there is no `.pbix` in the repo yet.
- Excel workpaper written by openpyxl.

## Layout

```
docs/        BRD, data dictionary, user stories (+ STATE/DECISIONS/VERIFY)
sql/         01 schema -> 02 views -> 03 load -> 04 verify; run in that order
scripts/     billing_rules.py (shared rules), generate_dataset.py, build_workpaper.py
powerbi/     dax_measures.md, dashboard_spec.md
workpapers/  generated Excel workpaper (committed so reviewers can open it)
data/        generated CSVs (gitignored; regenerate with the generator)
```

## Rules

1. **Business rules live in two places on purpose:** `scripts/billing_rules.py`
   and `sql/02_reconciliation_views.sql`. Change both, and record the change in
   `docs/DECISIONS.md` and BRD Section 6. `04_verify_detection.sql` must stay
   all PASS.
2. Money is `Decimal` in Python and `DECIMAL` in SQL. Never compare money as
   float. The SLA breach test cross-multiplies integers (see DECISIONS).
3. Leakage sign convention everywhere: positive = revenue lost, negative =
   customer overcharged.
4. Don't add dependencies without asking.
5. Run the checks in `docs/VERIFY.md` before reporting work as done.

## System Operating Modes

Each mode is a persona defined in `.claude/modes/`. It sets what to focus on,
how to judge the work, and the output format.

| Mode | File | Switch (Claude Code) | Badge |
| --- | --- | --- | --- |
| Business Analyst | `ba.md` | `/mode ba` or `/ba` | `[Mode: Business Analyst]` |
| System Architect | `architect.md` | `/mode architect` or `/architect` | `[Mode: System Architect]` |
| Engineer (**default**) | `engineer.md` | `/mode engineer` or `/code` | `[Mode: Engineer]` |
| Auditor | `auditor.md` | `/mode auditor` or `/audit` | `[Mode: Auditor]` |

- `/mode reset` returns to Engineer.
- **Start every response with the current mode's badge on its own line.** If no mode has been chosen this session, use `[Mode: Engineer]`.
- A mode lasts until it is switched or reset. The Rules above apply in every mode.
- Codex and `agy` don't have these slash commands. Say "switch to ba mode" and they read `.claude/modes/ba.md` directly.

## Read these too

- `docs/STATE.md`: where we stopped, what's next
- `docs/DECISIONS.md`: why things are the way they are
- `docs/VERIFY.md`: how to prove a change works
- `docs/BRD.md`: business rules (Section 6) and acceptance criteria (Section 7)

## Don't touch

- `audit_seeded_anomalies`: verification-only ground truth. Never join it into a reporting view.
- `workpapers/*.xlsx`: generated. Edit `scripts/build_workpaper.py` instead.
