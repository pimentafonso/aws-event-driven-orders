from __future__ import annotations

from typing import Any

import pytest

from .conftest import FakeContext, order, put_order, put_stock, stock

ITEMS = [{"sku": "SKU-1", "quantity": 2}, {"sku": "SKU-2", "quantity": 1}]


def run(steps: Any, action: str, order_id: str = "o-1", **extra: Any) -> dict[str, Any]:
    return steps.lambda_handler({"action": action, "order_id": order_id, **extra}, FakeContext())


@pytest.fixture
def stocked(tables: Any) -> Any:
    put_stock(tables, "SKU-1", 5)
    put_stock(tables, "SKU-2", 5)
    put_order(tables, "o-1", ITEMS)
    return tables


def test_reserve_takes_stock_and_marks_the_order(steps: Any, stocked: Any) -> None:
    result = run(steps, "reserve")

    assert result["status"] == "RESERVED"
    assert order(stocked, "o-1")["status"] == "RESERVED"
    assert (stock(stocked, "SKU-1"), stock(stocked, "SKU-2")) == (3, 4)


def test_reserve_twice_takes_stock_once(steps: Any, stocked: Any) -> None:
    run(steps, "reserve")
    result = run(steps, "reserve")

    assert result["status"] == "RESERVED"
    assert (stock(stocked, "SKU-1"), stock(stocked, "SKU-2")) == (3, 4)


def test_reserve_without_enough_stock_changes_nothing(steps: Any, stocked: Any) -> None:
    put_order(stocked, "o-2", [{"sku": "SKU-1", "quantity": 1}, {"sku": "SKU-2", "quantity": 6}])

    with pytest.raises(steps.OutOfStockError, match="SKU-2"):
        run(steps, "reserve", "o-2")

    assert order(stocked, "o-2")["status"] == "PENDING"
    assert (stock(stocked, "SKU-1"), stock(stocked, "SKU-2")) == (5, 5)


def test_reserve_unknown_product_is_out_of_stock(steps: Any, stocked: Any) -> None:
    put_order(stocked, "o-3", [{"sku": "NOPE", "quantity": 1}])

    with pytest.raises(steps.OutOfStockError):
        run(steps, "reserve", "o-3")


def test_charge_returns_a_stable_payment_id(steps: Any, stocked: Any) -> None:
    run(steps, "reserve")

    first, second = run(steps, "charge"), run(steps, "charge")

    assert first["payment_id"] == second["payment_id"]


def test_charge_declines_declined_customers(steps: Any, tables: Any) -> None:
    put_order(tables, "o-4", ITEMS, customer_id="declined-1", status="RESERVED")

    with pytest.raises(steps.PaymentDeclinedError):
        run(steps, "charge", "o-4")


def test_charge_refuses_an_order_that_is_not_reserved(steps: Any, stocked: Any) -> None:
    with pytest.raises(ValueError, match="PENDING"):
        run(steps, "charge")


def test_release_returns_stock_and_rejects(steps: Any, stocked: Any) -> None:
    run(steps, "reserve")

    result = run(steps, "release", reason="PAYMENT_DECLINED")

    assert result["status"] == "REJECTED"
    saved = order(stocked, "o-1")
    assert (saved["status"], saved["reason"]) == ("REJECTED", "PAYMENT_DECLINED")
    assert (stock(stocked, "SKU-1"), stock(stocked, "SKU-2")) == (5, 5)


def test_release_twice_returns_stock_once(steps: Any, stocked: Any) -> None:
    run(steps, "reserve")
    run(steps, "release", reason="PAYMENT_DECLINED")
    run(steps, "release", reason="PAYMENT_DECLINED")

    assert (stock(stocked, "SKU-1"), stock(stocked, "SKU-2")) == (5, 5)


def test_reject_sets_the_reason(steps: Any, stocked: Any) -> None:
    run(steps, "reject", reason="OUT_OF_STOCK")

    saved = order(stocked, "o-1")
    assert (saved["status"], saved["reason"]) == ("REJECTED", "OUT_OF_STOCK")


def test_confirm_is_idempotent(steps: Any, stocked: Any) -> None:
    run(steps, "reserve")

    assert run(steps, "confirm")["status"] == "CONFIRMED"
    assert run(steps, "confirm")["status"] == "CONFIRMED"


def test_confirm_refuses_a_rejected_order(steps: Any, stocked: Any) -> None:
    run(steps, "reject", reason="OUT_OF_STOCK")

    with pytest.raises(ValueError, match="REJECTED"):
        run(steps, "confirm")


def test_unknown_order_fails(steps: Any, tables: Any) -> None:
    with pytest.raises(steps.OrderNotFoundError):
        run(steps, "reserve", "missing")


def test_unknown_action_fails(steps: Any, stocked: Any) -> None:
    with pytest.raises(ValueError, match="unknown action"):
        run(steps, "refund")


def test_request_tokens_fit_dynamodb_limit(steps: Any) -> None:
    # DynamoDB rejects ClientRequestToken values longer than 36 characters;
    # moto does not check this, so the limit is tested here.
    order_id = "a3a32f68-4b5c-4b82-9923-ced95f2b9993"
    tokens = {steps._request_token(a, order_id) for a in ("reserve", "release")}

    assert all(len(t) <= 36 for t in tokens)
    assert len(tokens) == 2
    assert steps._request_token("reserve", order_id) == steps._request_token("reserve", order_id)
