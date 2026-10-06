"""Generate the RevRecon synthetic dataset as CSVs ready for MySQL LOAD DATA.

Writes to data/ (created if missing):
  dim_customer.csv, dim_contract.csv, fact_usage_events.csv, fact_invoices.csv
  anomaly_manifest.csv   ground truth for every seeded anomaly

Seeded anomalies are disjoint, so every exception has exactly one root cause:
  UNBILLED_USAGE          ~3% of usage events fall in periods with no invoice
  TIER_PRICING_VARIANCE    5% of issued invoices use another tier's discount
  MISSED_SLA_CREDIT        2% of issued invoices skip a credit the SLA requires

The same seed always produces byte-identical files.

    python scripts/generate_dataset.py
    python scripts/generate_dataset.py --customers 120 --seed 7 --out data
"""

from __future__ import annotations

import argparse
import calendar
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path

import numpy as np
import pandas as pd
from faker import Faker

from billing_rules import ZERO, classify, expected_charge, money, sla_credit_pct

WINDOW_START = date(2025, 10, 1)
WINDOW_MONTHS = 12

# Commercial terms per tier. Discounts and SLA targets are the rate card
# (BRD BR-01, BR-03); base rates and volumes are realistic synthetic ranges.
TIERS = {
    "Enterprise": {"discount": Decimal("0.20"), "sla": Decimal("99.50"), "rate": (0.060, 0.090), "events": 120, "share": 0.30},
    "Growth":     {"discount": Decimal("0.10"), "sla": Decimal("99.00"), "rate": (0.090, 0.130), "events": 70,  "share": 0.35},
    "Starter":    {"discount": Decimal("0.00"), "sla": Decimal("98.00"), "rate": (0.130, 0.180), "events": 40,  "share": 0.35},
}
REGIONS = ["NA", "EMEA", "APAC", "LATAM"]
REGION_WEIGHTS = [0.40, 0.30, 0.20, 0.10]

UNBILLED_EVENT_SHARE = 0.03
WRONG_PRICING_SHARE = 0.05
MISSED_CREDIT_SHARE = 0.02

INCIDENT_PROB = 0.15          # chance a contract-period has an outage
INCIDENT_ERROR_RATE = (0.01, 0.05)
BASELINE_ERROR_RATE = 0.0005

MIN_EVENTS = 5000


def month_starts(first: date, count: int) -> list[date]:
    months, year, month = [], first.year, first.month
    for _ in range(count):
        months.append(date(year, month, 1))
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    return months


def add_months(day: date, months: int) -> date:
    index = day.month - 1 + months
    year, month = day.year + index // 12, index % 12 + 1
    return date(year, month, min(day.day, calendar.monthrange(year, month)[1]))


def build_customers(n: int, rng: np.random.Generator, fake: Faker) -> tuple[list[dict], list[dict]]:
    tiers = list(TIERS)
    shares = [TIERS[t]["share"] for t in tiers]
    pre_window = month_starts(date(2024, 1, 1), 21)       # Jan 2024 .. Sep 2025
    in_window = month_starts(WINDOW_START, 6)              # Oct 2025 .. Mar 2026

    customers, contracts = [], []
    for i in range(1, n + 1):
        tier = str(rng.choice(tiers, p=shares))
        terms = TIERS[tier]
        # Contracts start on the 1st so every billing period is a whole month.
        if rng.random() < 0.7:
            start, term_months = pre_window[rng.integers(len(pre_window))], 36
        else:
            start, term_months = in_window[rng.integers(len(in_window))], 24
        scale = float(rng.uniform(0.6, 1.4))               # this customer's appetite
        monthly_units = terms["events"] * scale * 32       # ~32 billable units per call
        customers.append({
            "customer_id": i,
            "company_name": fake.unique.company(),
            "tier": tier,
            "region": str(rng.choice(REGIONS, p=REGION_WEIGHTS)),
            "signup_date": start - timedelta(days=int(rng.integers(7, 61))),
        })
        contracts.append({
            "contract_id": 5000 + i,
            "customer_id": i,
            "start_date": start,
            "end_date": add_months(start, term_months) - timedelta(days=1),
            # Commitment sits near typical usage, so some months fall below it.
            "committed_volume": int(round(monthly_units * rng.uniform(0.8, 1.1), -2)),
            "base_rate": Decimal(f"{rng.uniform(*terms['rate']):.4f}"),
            "tier_discount_rate": terms["discount"],
            "sla_uptime_target": terms["sla"],
            "_scale": scale,
            "_tier": tier,
        })
    return customers, contracts


def build_usage(contracts: list[dict], rng: np.random.Generator) -> tuple[pd.DataFrame, list[dict]]:
    frames, periods = [], []
    for c in contracts:
        mean_events = TIERS[c["_tier"]]["events"] * c["_scale"]
        for period in month_starts(WINDOW_START, WINDOW_MONTHS):
            if period < c["start_date"]:
                continue
            n = max(5, int(rng.poisson(mean_events)))
            if rng.random() < INCIDENT_PROB:
                error_rate = rng.uniform(*INCIDENT_ERROR_RATE)
            else:
                error_rate = BASELINE_ERROR_RATE
            is_error = rng.random(n) < error_rate
            seconds_in_month = calendar.monthrange(period.year, period.month)[1] * 86400
            offsets = np.sort(rng.integers(0, seconds_in_month, n))
            latency = rng.lognormal(np.log(120), 0.35, n)
            latency = np.where(is_error, rng.uniform(3000, 10000, n), latency)
            # Failed calls are not chargeable (BR-02).
            units = np.where(is_error, 0, rng.integers(5, 61, n))

            frames.append(pd.DataFrame({
                "customer_id": c["customer_id"],
                "contract_id": c["contract_id"],
                "timestamp": [datetime.combine(period, datetime.min.time()) + timedelta(seconds=int(s)) for s in offsets],
                "units_consumed": units.astype(int),
                "response_latency_ms": latency.round().astype(int),
                "is_error": is_error.astype(int),
            }))

            event_count, error_events = n, int(is_error.sum())
            credit_pct = sla_credit_pct(event_count, error_events, c["sla_uptime_target"])
            gross, credit, net = expected_charge(
                int(units.sum()), c["committed_volume"], c["base_rate"], c["tier_discount_rate"], credit_pct
            )
            periods.append({
                "customer_id": c["customer_id"], "contract_id": c["contract_id"], "billing_period": period,
                "event_count": event_count, "units": int(units.sum()), "credit_pct": credit_pct,
                "gross": gross, "credit": credit, "net": net,
                "billable_units": max(int(units.sum()), c["committed_volume"]),
                "base_rate": c["base_rate"], "discount": c["tier_discount_rate"],
            })

    events = pd.concat(frames, ignore_index=True).sort_values(["timestamp", "contract_id"], kind="stable")
    events.insert(0, "event_id", np.arange(1, len(events) + 1))
    return events.reset_index(drop=True), periods


def seed_anomalies(periods: list[dict], total_events: int, rng: np.random.Generator) -> list[dict]:
    """Mark each period with its billed amount and anomaly (or None). Returns the manifest."""
    manifest = []

    # UNBILLED_USAGE: drop whole invoices until ~3% of events have no invoice.
    unbilled_events = 0
    for idx in rng.permutation(len(periods)):
        if unbilled_events >= UNBILLED_EVENT_SHARE * total_events:
            break
        p = periods[idx]
        p["anomaly"], p["billed"] = "UNBILLED_USAGE", None
        unbilled_events += p["event_count"]

    issued = [p for p in periods if p.get("anomaly") is None]
    for p in issued:
        p["anomaly"], p["billed"] = None, p["net"]

    # TIER_PRICING_VARIANCE: another tier's discount, on periods with no SLA credit
    # due, so the pricing error is the only thing wrong with the invoice.
    clean = [p for p in issued if p["credit_pct"] == ZERO]
    n_wrong = round(WRONG_PRICING_SHARE * len(issued))
    discounts = sorted({t["discount"] for t in TIERS.values()})
    for idx in rng.choice(len(clean), n_wrong, replace=False):
        p = clean[idx]
        wrong = Decimal(rng.choice([d for d in discounts if d != p["discount"]]))
        p["anomaly"] = "TIER_PRICING_VARIANCE"
        p["billed"] = money(p["billable_units"] * p["base_rate"] * (1 - wrong))
        p["detail"] = f"applied discount {wrong} instead of {p['discount']}"

    # MISSED_SLA_CREDIT: breached periods invoiced at gross.
    breached = [p for p in issued if p["credit_pct"] > ZERO]
    n_missed = round(MISSED_CREDIT_SHARE * len(issued))
    assert len(breached) >= n_missed, f"only {len(breached)} breached periods, need {n_missed}"
    for idx in rng.choice(len(breached), n_missed, replace=False):
        p = breached[idx]
        p["anomaly"], p["billed"] = "MISSED_SLA_CREDIT", p["gross"]
        p["detail"] = f"credit of {p['credit']} ({p['credit_pct']:.0%}) not deducted"

    for p in periods:
        if p["anomaly"]:
            billed = p["billed"] if p["billed"] is not None else ZERO
            manifest.append({
                "anomaly_type": p["anomaly"],
                "customer_id": p["customer_id"],
                "contract_id": p["contract_id"],
                "billing_period": p["billing_period"],
                "event_count": p["event_count"],
                "expected_amount": p["net"],
                "billed_amount": p["billed"],
                "leakage_amount": p["net"] - billed,
                "detail": p.get("detail", f"no invoice for {p['event_count']} events"),
            })
    return manifest


def build_invoices(periods: list[dict], rng: np.random.Generator) -> pd.DataFrame:
    issued = sorted((p for p in periods if p["billed"] is not None),
                    key=lambda p: (p["billing_period"], p["contract_id"]))
    last, second_last = month_starts(WINDOW_START, WINDOW_MONTHS)[-1], month_starts(WINDOW_START, WINDOW_MONTHS)[-2]
    rows = []
    for i, p in enumerate(issued):
        if p["billing_period"] == last:
            status = "OPEN"
        elif p["billing_period"] == second_last:
            status = "PAID" if rng.random() < 0.6 else "OPEN"
        else:
            status = "PAID" if rng.random() < 0.96 else "OVERDUE"
        p["invoice_id"] = 100001 + i
        rows.append({
            "invoice_id": p["invoice_id"],
            "customer_id": p["customer_id"],
            "contract_id": p["contract_id"],
            "billing_period": p["billing_period"],
            "billed_amount": p["billed"],
            "invoice_status": status,
        })
    return pd.DataFrame(rows)


def write_csv(df: pd.DataFrame, path: Path) -> None:
    # \N is MySQL's NULL marker for LOAD DATA; \n line endings match 03_load_data.sql.
    df.to_csv(path, index=False, na_rep="\\N", lineterminator="\n", date_format="%Y-%m-%d %H:%M:%S")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent.parent / "data")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--customers", type=int, default=60)
    args = parser.parse_args()

    rng = np.random.default_rng(args.seed)
    Faker.seed(args.seed)
    fake = Faker("en_US")

    customers, contracts = build_customers(args.customers, rng, fake)
    events, periods = build_usage(contracts, rng)
    manifest = seed_anomalies(periods, len(events), rng)
    invoices = build_invoices(periods, rng)
    for row in manifest:
        row["invoice_id"] = next((p.get("invoice_id") for p in periods
                                  if p["contract_id"] == row["contract_id"]
                                  and p["billing_period"] == row["billing_period"]), None)

    args.out.mkdir(parents=True, exist_ok=True)
    write_csv(pd.DataFrame(customers), args.out / "dim_customer.csv")
    write_csv(pd.DataFrame(contracts).drop(columns=["_scale", "_tier"]), args.out / "dim_contract.csv")
    write_csv(events, args.out / "fact_usage_events.csv")
    write_csv(invoices, args.out / "fact_invoices.csv")
    manifest_df = pd.DataFrame(manifest)[[
        "anomaly_type", "customer_id", "contract_id", "billing_period", "invoice_id",
        "event_count", "expected_amount", "billed_amount", "leakage_amount", "detail",
    ]]
    manifest_df["invoice_id"] = manifest_df["invoice_id"].astype("Int64")
    write_csv(manifest_df, args.out / "anomaly_manifest.csv")

    # Self-check: the realised anomaly rates match the brief, and the shared
    # classifier finds exactly the anomalies that were seeded.
    n_issued = len(invoices)
    counts = manifest_df["anomaly_type"].value_counts()
    unbilled_events = manifest_df.loc[manifest_df["anomaly_type"] == "UNBILLED_USAGE", "event_count"].sum()
    unbilled_share = unbilled_events / len(events)
    assert len(events) >= MIN_EVENTS, f"{len(events)} events, need at least {MIN_EVENTS}"
    assert 0.03 <= unbilled_share < 0.035, f"unbilled share {unbilled_share:.2%}"
    assert counts["TIER_PRICING_VARIANCE"] == round(WRONG_PRICING_SHARE * n_issued)
    assert counts["MISSED_SLA_CREDIT"] == round(MISSED_CREDIT_SHARE * n_issued)
    for p in periods:
        found = classify(p["billed"], p["gross"], p["credit"], p["net"])
        assert found == (p["anomaly"] or "RECONCILED"), (p["contract_id"], p["billing_period"], found, p["anomaly"])

    breached = sum(1 for p in periods if p["credit_pct"] > ZERO)
    print(f"Wrote {args.out}")
    print(f"  customers {len(customers)} | contracts {len(contracts)} | usage events {len(events):,} | "
          f"invoices {n_issued} | contract-periods {len(periods)} | SLA breaches {breached}")
    print(f"  UNBILLED_USAGE         {counts['UNBILLED_USAGE']:>3} periods, {unbilled_events:,} events ({unbilled_share:.2%} of events)")
    print(f"  TIER_PRICING_VARIANCE  {counts['TIER_PRICING_VARIANCE']:>3} invoices ({counts['TIER_PRICING_VARIANCE'] / n_issued:.2%})")
    print(f"  MISSED_SLA_CREDIT      {counts['MISSED_SLA_CREDIT']:>3} invoices ({counts['MISSED_SLA_CREDIT'] / n_issued:.2%})")
    print(f"  Net leakage seeded     {manifest_df['leakage_amount'].sum():,.2f}")


if __name__ == "__main__":
    main()
