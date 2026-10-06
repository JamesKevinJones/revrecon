# Project State

> Updated at the end of every session, by whichever agent was driving.
> Keep it under a page. This is a baton, not a diary.

**Last updated:** 2026-10-06 by claude-code

## Where things stand

The full scaffold is built and verified end to end. `generate_dataset.py`
writes deterministic CSVs with seeded anomalies. All four SQL files run on
MySQL 8.4, and `04_verify_detection.sql` returns PASS on every check: 70 of 70
anomalies detected, no false positives, and leakage that matches to the cent.
`build_workpaper.py` writes the Excel workpaper, and its Python re-performance
agrees with the seeded truth. The BRD, data dictionary, user stories, DAX
catalog and dashboard spec are written.

## In progress

- [ ] Nothing half-done.

## The exact next step

Build the `.pbix` in Power BI Desktop from `powerbi/dax_measures.md` and
`powerbi/dashboard_spec.md`. Connect to MySQL with the MySQL connector, or
import the CSVs plus a CSV export of the three views. Then confirm that the
cards match the "Reconciliation checks" table in `dax_measures.md`.

## Open questions

- BRD OQ-1 to OQ-5 (credit line on invoices, zero-usage commitment periods,
  refund vs credit for over-billing, SLA measurement basis, proration). All
  need a business decision; don't guess them in code.

## Known traps

- `timestamp` is a column name. Backtick it in MySQL.
- `LOAD DATA LOCAL INFILE` needs `--local-infile=1` on the client **and**
  `local_infile=ON` on the server, and `03_load_data.sql` must run from the
  repository root, because its paths are relative.
- In WSL Docker, start the keep-alive first, or the container dies between commands.
- The Excel Summary sheet holds formulas. openpyxl writes them but doesn't
  evaluate them, so the values only appear when the file is opened in Excel.
