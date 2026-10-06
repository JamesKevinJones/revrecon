"""Billing and SLA credit rules (BRD Section 6, BR-01 to BR-05).

Shared by generate_dataset.py and build_workpaper.py. The SQL views in
sql/02_reconciliation_views.sql implement the same rules independently, and
sql/04_verify_detection.sql proves the two agree. Change a rule here and you
must change it there too.

Money is Decimal throughout. MySQL's DECIMAL arithmetic is exact and ROUND()
rounds half away from zero, so float maths here would drift by a cent on some
invoices and show up as false exceptions.
"""

from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal

CENT = Decimal("0.01")
ZERO = Decimal("0")

# BR-04: credit schedule for an SLA breach in a billing period.
MINOR_CREDIT_PCT = Decimal("0.10")   # availability below target
MAJOR_CREDIT_PCT = Decimal("0.25")   # availability at least 1 point below target
MAJOR_SHORTFALL_PTS = Decimal("1.00")

# BR-05: invoices within a cent of expectation reconcile.
TOLERANCE = Decimal("0.01")


def money(value: Decimal) -> Decimal:
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def sla_credit_pct(event_count: int, error_events: int, target_pct: Decimal) -> Decimal:
    """Credit rate owed for one contract-period (BR-03, BR-04).

    availability = 100 * (events - errors) / events. Comparing it to the target
    by cross-multiplying keeps the boundary exact: an availability of exactly
    99.50 against a 99.50 target is not a breach.
    """
    errors_x100 = 100 * error_events
    if errors_x100 >= (100 - target_pct + MAJOR_SHORTFALL_PTS) * event_count:
        return MAJOR_CREDIT_PCT
    if errors_x100 > (100 - target_pct) * event_count:
        return MINOR_CREDIT_PCT
    return ZERO


def expected_charge(
    units: int,
    committed_volume: int,
    base_rate: Decimal,
    discount_rate: Decimal,
    credit_pct: Decimal,
) -> tuple[Decimal, Decimal, Decimal]:
    """(gross, credit, net) for one contract-period (BR-01, BR-02, BR-04)."""
    billable_units = max(units, committed_volume)
    gross = money(billable_units * base_rate * (1 - discount_rate))
    credit = money(gross * credit_pct)
    return gross, credit, gross - credit


def classify(
    billed: Decimal | None, gross: Decimal, credit: Decimal, net: Decimal
) -> str:
    """Exception type for one contract-period, mirroring vw_billing_reconciliation."""
    if billed is None:
        return "UNBILLED_USAGE"
    if credit > 0 and abs(billed - gross) <= TOLERANCE:
        return "MISSED_SLA_CREDIT"
    if abs(billed - net) > TOLERANCE:
        return "TIER_PRICING_VARIANCE"
    return "RECONCILED"


if __name__ == "__main__":
    target = Decimal("99.50")
    assert sla_credit_pct(200, 1, target) == ZERO               # exactly 99.50: no breach
    assert sla_credit_pct(200, 2, target) == MINOR_CREDIT_PCT   # 99.00: below target
    assert sla_credit_pct(200, 3, target) == MAJOR_CREDIT_PCT   # 98.50: 1 point below
    assert expected_charge(500, 1000, Decimal("0.1000"), Decimal("0.20"), ZERO) == (
        Decimal("80.00"), Decimal("0.00"), Decimal("80.00"),
    )  # commitment minimum applies
    assert classify(None, Decimal(1), ZERO, Decimal(1)) == "UNBILLED_USAGE"
    assert classify(Decimal("90"), Decimal("90"), Decimal("9"), Decimal("81")) == "MISSED_SLA_CREDIT"
    assert classify(Decimal("70"), Decimal("80"), ZERO, Decimal("80")) == "TIER_PRICING_VARIANCE"
    assert classify(Decimal("80.01"), Decimal("80"), ZERO, Decimal("80")) == "RECONCILED"
    print("billing_rules: all checks passed")
