# Verification

Exact commands to prove a change works. Run them from the repository root in
PowerShell.

Rule: **don't report work as done without running these.** "It should work" is
not a result.

## Install

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r scripts\requirements.txt
```

## Rule self-checks (no database)

```powershell
.\.venv\Scripts\python.exe scripts\billing_rules.py
```

Expected: `billing_rules: all checks passed`. This proves AC-3 and AC-5.

## Generate data

```powershell
.\.venv\Scripts\python.exe scripts\generate_dataset.py
```

Expected (seed 42): 57,071 usage events, 667 invoices, and 691 contract-periods.
UNBILLED_USAGE is 24 periods covering 1,724 events (3.02%), TIER_PRICING_VARIANCE
is 33 invoices (4.95%), MISSED_SLA_CREDIT is 13 invoices (1.95%), and net leakage
seeded is 4,507.45. The script asserts the rates itself and exits non-zero if
they drift. The same seed always produces byte-identical CSVs.

## SQL against MySQL (the main check)

A throwaway MySQL 8.4 in WSL Docker. Start the WSL keep-alive first
(`wsl.exe -e bash -lc "sleep infinity"`, backgrounded), then run this from the
repository root inside WSL. The password only protects a local container
bound to 127.0.0.1, which is deleted at the end.

```bash
docker run -d --name revrecon-mysql -e MYSQL_ROOT_PASSWORD=revrecon-test \
  -v "$(pwd):/work:ro" -p 127.0.0.1:33306:3306 mysql:8.4 --local-infile=1
# wait about 20 s for mysqld, then:
for f in 01_schema 02_reconciliation_views 03_load_data 04_verify_detection; do
  docker exec -i -w /work revrecon-mysql mysql --local-infile=1 -uroot -prevrecon-test --table < "sql/$f.sql"
done
docker rm -f revrecon-mysql
```

Expected from `04_verify_detection.sql`: **every row reads PASS**, as below.

| check_name | seeded | detected | missed | false_positives |
| --- | --- | --- | --- | --- |
| MISSED_SLA_CREDIT | 13 | 13 | 0 | 0 |
| ORPHANED_EVENTS | 1724 | 1724 | | |
| SLA_CREDIT_MISSED | 13 | 13 | | |
| TIER_PRICING_VARIANCE | 33 | 33 | 0 | 0 |
| UNBILLED_USAGE | 24 | 24 | 0 | 0 |

The headline row should then read: 691 contract-periods, 70 exceptions,
expected 159,591.23, billed 155,083.78, net leakage 4,507.45, and 2.82% exposure.

Last verified: 2026-10-06, MySQL 8.4, loaded in about 2 s.

## Workpaper

```powershell
.\.venv\Scripts\python.exe scripts\build_workpaper.py
```

Expected: "691 contract-periods, 70 exceptions (re-performance matches all 70
seeded anomalies)". The script asserts that match. The Summary sheet's
formulas only evaluate when the workbook is opened in Excel. Its Total
Expected and Net Leakage should then equal the SQL headline row.

## Power BI

This can't be automated. Follow the publishing checklist in
`powerbi/dashboard_spec.md` and the reconciliation checks table in
`powerbi/dax_measures.md`.

## Known-failing

- None.
