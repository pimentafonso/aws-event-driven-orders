from __future__ import annotations

import uuid
from typing import Any

import pytest

from .conftest import call, http_event

ORDER = {"customer_id": "c-1", "items": [{"sku": "SKU-1", "quantity": 2}]}


def post(app: Any, body: Any, key: str | None = "key-00000001", **kwargs: Any):
    headers = {"idempotency-key": key} if key is not None else {}
    return call(app, http_event("POST", "/orders", body, headers, **kwargs))


def test_create_returns_201_with_location(app: Any, tables: Any) -> None:
    status, body, headers = post(app, ORDER)

    assert status == 201
    assert uuid.UUID(body["order_id"])
    assert body["status"] == "PENDING"
    assert body["items"] == ORDER["items"]
    assert headers["Location"] == f"/orders/{body['order_id']}"
    assert tables["orders"].scan()["Count"] == 1


def test_same_key_and_body_replays_the_first_order(app: Any, tables: Any) -> None:
    _, first, _ = post(app, ORDER)
    status, second, _ = post(app, ORDER)

    assert status == 201
    assert second == first
    assert tables["orders"].scan()["Count"] == 1


def test_same_key_with_a_different_order_is_rejected(app: Any, tables: Any) -> None:
    post(app, ORDER)
    other = {**ORDER, "items": [{"sku": "SKU-1", "quantity": 3}]}
    status, body, _ = post(app, other)

    assert status == 422
    assert "different order" in body["message"]
    assert tables["orders"].scan()["Count"] == 1


def test_different_keys_create_different_orders(app: Any, tables: Any) -> None:
    _, first, _ = post(app, ORDER, key="key-00000001")
    _, second, _ = post(app, ORDER, key="key-00000002")

    assert first["order_id"] != second["order_id"]
    assert tables["orders"].scan()["Count"] == 2


@pytest.mark.parametrize("key", [None, "short", "has space in it", "x" * 129])
def test_missing_or_malformed_key_is_rejected(app: Any, tables: Any, key: str | None) -> None:
    status, body, _ = post(app, ORDER, key=key)

    assert status == 400
    assert "Idempotency-Key" in body["message"]
    assert tables["orders"].scan()["Count"] == 0


@pytest.mark.parametrize(
    "order",
    [
        [],
        {"items": [{"sku": "A", "quantity": 1}]},
        {"customer_id": "c-1", "items": []},
        {"customer_id": "c-1", "items": [{"sku": "A", "quantity": 0}]},
        {"customer_id": "c-1", "items": [{"sku": "A", "quantity": 101}]},
        {"customer_id": "c-1", "items": [{"sku": "A", "quantity": True}]},
        {"customer_id": "c-1", "items": [{"sku": "A", "quantity": 1.5}]},
        {"customer_id": "c-1", "items": [{"sku": "A", "quantity": 1}, {"sku": "A", "quantity": 2}]},
        {"customer_id": "c 1", "items": [{"sku": "A", "quantity": 1}]},
        {"customer_id": "c-1", "items": [{"sku": "A", "quantity": 1, "price": 9}]},
        {"customer_id": "c-1", "items": [{"sku": "A", "quantity": 1}], "total": 9},
    ],
)
def test_invalid_orders_are_rejected(app: Any, tables: Any, order: Any) -> None:
    status, _, _ = post(app, order)

    assert status == 400
    assert tables["orders"].scan()["Count"] == 0


def test_body_that_is_not_json_is_rejected(app: Any, tables: Any) -> None:
    status, body, _ = post(app, None, raw_body="{not json")

    assert status == 400
    assert "JSON" in body["message"]


def test_rejected_request_does_not_burn_the_key(app: Any, tables: Any) -> None:
    post(app, {"customer_id": "c-1", "items": []})
    status, _, _ = post(app, ORDER)

    assert status == 201


def test_get_returns_the_created_order(app: Any, tables: Any) -> None:
    _, created, _ = post(app, ORDER)
    status, body, _ = call(app, http_event("GET", f"/orders/{created['order_id']}"))

    assert status == 200
    assert body == created


@pytest.mark.parametrize("order_id", [str(uuid.uuid4()), "not-a-uuid"])
def test_get_unknown_order_is_404(app: Any, tables: Any, order_id: str) -> None:
    status, _, _ = call(app, http_event("GET", f"/orders/{order_id}"))

    assert status == 404
