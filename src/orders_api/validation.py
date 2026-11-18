"""Request validation for new orders, without third-party dependencies."""

from __future__ import annotations

import re
from typing import Any

MAX_ITEMS = 20
MAX_QUANTITY = 100
_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

# Idempotency keys: printable ASCII without spaces, 8-128 characters (a UUID fits).
IDEMPOTENCY_KEY = re.compile(r"^[!-~]{8,128}$")


class InvalidOrderError(ValueError):
    """The request body is not a valid order."""


def parse_new_order(body: Any) -> dict[str, Any]:
    """Return a normalised order request, or raise InvalidOrderError.

    Expected shape:
        {"customer_id": "c-1", "items": [{"sku": "SKU-1", "quantity": 2}]}
    """
    if not isinstance(body, dict):
        raise InvalidOrderError("body must be a JSON object")

    unknown = set(body) - {"customer_id", "items"}
    if unknown:
        raise InvalidOrderError(f"unknown fields: {', '.join(sorted(unknown))}")

    customer_id = body.get("customer_id")
    if not isinstance(customer_id, str) or not _ID.match(customer_id):
        raise InvalidOrderError("customer_id must be 1-64 letters, digits, '-' or '_'")

    items = body.get("items")
    if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
        raise InvalidOrderError(f"items must be a list of 1-{MAX_ITEMS} entries")

    quantities: dict[str, int] = {}
    for item in items:
        if not isinstance(item, dict) or set(item) != {"sku", "quantity"}:
            raise InvalidOrderError("each item must have exactly 'sku' and 'quantity'")
        sku, quantity = item["sku"], item["quantity"]
        if not isinstance(sku, str) or not _ID.match(sku):
            raise InvalidOrderError("sku must be 1-64 letters, digits, '-' or '_'")
        # bool is a subclass of int in Python; reject true/false explicitly.
        if isinstance(quantity, bool) or not isinstance(quantity, int):
            raise InvalidOrderError("quantity must be an integer")
        if not 1 <= quantity <= MAX_QUANTITY:
            raise InvalidOrderError(f"quantity must be 1-{MAX_QUANTITY}")
        if sku in quantities:
            raise InvalidOrderError(f"duplicate sku: {sku}")
        quantities[sku] = quantity

    return {
        "customer_id": customer_id,
        "items": [{"sku": s, "quantity": q} for s, q in quantities.items()],
    }
