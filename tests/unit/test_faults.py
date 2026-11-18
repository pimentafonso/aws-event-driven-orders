from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

import faults

from .conftest import FakeContext, put_order, put_stock
from .test_notifier import confirmed, handle, notifications, sqs_record

ASL = Path(__file__).parents[2] / "infra" / "modules" / "events" / "saga.asl.json"


@pytest.fixture
def switch(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """The fault switch's value, without Parameter Store."""
    values: dict[str, Any] = {}
    monkeypatch.setattr(faults, "_load", lambda: values)
    return values


def test_no_parameter_means_no_faults(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("FAULTS_PARAMETER", raising=False)

    assert faults.rate(faults.PAYMENT_UNAVAILABLE) == 0
    assert not faults.should_fail(faults.PAYMENT_UNAVAILABLE)


def test_an_unreadable_switch_means_no_faults(monkeypatch: pytest.MonkeyPatch) -> None:
    def broken(*_: Any, **__: Any) -> Any:
        raise RuntimeError("AccessDenied")

    monkeypatch.setenv("FAULTS_PARAMETER", "/aedo-test/faults")
    monkeypatch.setattr(faults, "get_parameter", broken)

    assert faults.rate(faults.NOTIFIER_FAILURE) == 0


@pytest.mark.parametrize(("value", "expected"), [(0.25, 0.25), (7, 1.0), (-1, 0.0), ("x", 0.0)])
def test_rates_are_clamped(switch: dict[str, Any], value: Any, expected: float) -> None:
    switch[faults.NOTIFIER_FAILURE] = value

    assert faults.rate(faults.NOTIFIER_FAILURE) == expected


def test_charge_fails_when_the_provider_is_down(steps: Any, tables: Any, switch: dict) -> None:
    put_stock(tables, "SKU-1", 5)
    put_order(tables, "o-1", [{"sku": "SKU-1", "quantity": 1}], status="RESERVED")
    switch[faults.PAYMENT_UNAVAILABLE] = 1

    with pytest.raises(steps.PaymentProviderUnavailableError):
        steps.lambda_handler({"action": "charge", "order_id": "o-1"}, FakeContext())


def test_notifier_failure_fails_only_that_message(notifier: Any, tables: Any, switch: dict) -> None:
    switch[faults.NOTIFIER_FAILURE] = 1

    response = handle(notifier, sqs_record("m1", confirmed("o-1")))

    assert response == {"batchItemFailures": [{"itemIdentifier": "m1"}]}
    assert notifications(tables) == []


def test_the_saga_retries_an_unavailable_provider_then_compensates() -> None:
    charge = json.loads(ASL.read_text(encoding="utf-8"))["States"]["ChargePayment"]

    retry = [r for r in charge["Retry"] if r["ErrorEquals"] == ["PaymentProviderUnavailableError"]]
    catch_all = [c for c in charge["Catch"] if c["ErrorEquals"] == ["States.ALL"]]

    assert retry and retry[0]["MaxAttempts"] == 3
    assert catch_all and catch_all[0]["Next"] == "ReleaseStockFailed"
