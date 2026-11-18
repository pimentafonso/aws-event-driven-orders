"""Saga steps for one order, called by Step Functions with {"action": ..., "order_id": ...}.

Order status moves PENDING -> RESERVED -> CONFIRMED, or ends REJECTED with a
reason. Every step is idempotent: events are delivered at least once, so the
same order can start two executions, and Step Functions retries failed tasks.
Each step checks the current status and does nothing if it already ran.

Errors that the state machine catches by name:
    OutOfStockError       not enough stock for at least one item
    PaymentDeclinedError  the simulated payment provider said no
"""

from __future__ import annotations

import os
import uuid
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext
from botocore.exceptions import ClientError

logger = Logger()
tracer = Tracer()
metrics = Metrics()

TABLE_NAME = os.environ["ORDERS_TABLE"]
table = boto3.resource("dynamodb").Table(TABLE_NAME)
client = boto3.client("dynamodb")

# Payment simulation: customers whose ID starts with this prefix are declined.
DECLINED_PREFIX = "declined"


class OutOfStockError(Exception):
    """At least one item does not have enough stock."""


class PaymentDeclinedError(Exception):
    """The simulated payment was declined."""


class OrderNotFoundError(Exception):
    """The order in the event does not exist."""


def _request_token(action: str, order_id: str) -> str:
    """Idempotency token for a transaction: stable per step and order.

    DynamoDB allows at most 36 characters, so a name-based UUID is used
    rather than "<action>-<order_id>", which would be 44.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"aedo:{action}:{order_id}"))


def _order_key(order_id: str) -> dict[str, str]:
    return {"pk": f"ORDER#{order_id}", "sk": "ORDER"}


def _stock_key(sku: str) -> dict[str, dict[str, str]]:
    return {"pk": {"S": f"PRODUCT#{sku}"}, "sk": {"S": "STOCK"}}


def _load(order_id: str) -> dict[str, Any]:
    item = table.get_item(Key=_order_key(order_id), ConsistentRead=True).get("Item")
    if item is None:
        raise OrderNotFoundError(order_id)
    return item


def _result(order: dict[str, Any], **extra: Any) -> dict[str, Any]:
    return {
        "order_id": order["order_id"],
        "customer_id": order["customer_id"],
        "status": order["status"],
        **extra,
    }


def _order_update(order_id: str, new_status: str, expected: str, reason: str | None) -> dict:
    names = {"#s": "status"}
    values: dict[str, Any] = {":new": {"S": new_status}, ":expected": {"S": expected}}
    expression = "SET #s = :new"
    if reason:
        expression += ", reason = :reason"
        values[":reason"] = {"S": reason}
    return {
        "Update": {
            "TableName": TABLE_NAME,
            "Key": {"pk": {"S": f"ORDER#{order_id}"}, "sk": {"S": "ORDER"}},
            "UpdateExpression": expression,
            "ConditionExpression": "#s = :expected",
            "ExpressionAttributeNames": names,
            "ExpressionAttributeValues": values,
        }
    }


def _stock_update(sku: str, delta: int) -> dict:
    update: dict[str, Any] = {
        "TableName": TABLE_NAME,
        "Key": _stock_key(sku),
        "UpdateExpression": "SET available = available + :delta",
        "ExpressionAttributeValues": {":delta": {"N": str(delta)}},
    }
    if delta < 0:
        # Only take stock that is there; the product must exist.
        update["ConditionExpression"] = "available >= :needed"
        update["ExpressionAttributeValues"][":needed"] = {"N": str(-delta)}
    return {"Update": update}


def _cancellation_codes(err: ClientError) -> list[str]:
    reasons = err.response.get("CancellationReasons", [])
    return [r.get("Code", "None") for r in reasons]


def reserve(order_id: str) -> dict[str, Any]:
    order = _load(order_id)
    if order["status"] != "PENDING":
        logger.info("reserve skipped", extra={"status": order["status"]})
        return _result(order)

    items = [(i["sku"], int(i["quantity"])) for i in order["items"]]
    try:
        client.transact_write_items(
            TransactItems=[
                _order_update(order_id, "RESERVED", "PENDING", None),
                *(_stock_update(sku, -quantity) for sku, quantity in items),
            ],
            ClientRequestToken=_request_token("reserve", order_id),
        )
    except ClientError as err:
        if err.response["Error"]["Code"] != "TransactionCanceledException":
            raise
        codes = _cancellation_codes(err)
        if codes and codes[0] == "ConditionalCheckFailed":
            # Another execution moved the order on first; nothing to do.
            return _result(_load(order_id))
        short = [sku for (sku, _), code in zip(items, codes[1:], strict=False) if code != "None"]
        raise OutOfStockError(f"not enough stock for {', '.join(short) or 'some items'}") from err

    metrics.add_metric(name="StockReserved", unit=MetricUnit.Count, value=1)
    return _result({**order, "status": "RESERVED"})


def charge(order_id: str) -> dict[str, Any]:
    order = _load(order_id)
    if order["status"] not in ("RESERVED", "CONFIRMED"):
        raise ValueError(f"cannot charge an order in status {order['status']}")
    if order["customer_id"].startswith(DECLINED_PREFIX):
        metrics.add_metric(name="PaymentsDeclined", unit=MetricUnit.Count, value=1)
        raise PaymentDeclinedError(f"payment declined for customer {order['customer_id']}")
    # A real provider would get this as its idempotency key, so a retried
    # charge never bills twice.
    payment_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"aedo:payment:{order_id}"))
    return _result(order, payment_id=payment_id)


def release(order_id: str, reason: str) -> dict[str, Any]:
    """Compensation: give the reserved stock back and reject the order."""
    order = _load(order_id)
    if order["status"] != "RESERVED":
        logger.info("release skipped", extra={"status": order["status"]})
        return _result(order)
    items = [(i["sku"], int(i["quantity"])) for i in order["items"]]
    try:
        client.transact_write_items(
            TransactItems=[
                _order_update(order_id, "REJECTED", "RESERVED", reason),
                *(_stock_update(sku, quantity) for sku, quantity in items),
            ],
            ClientRequestToken=_request_token("release", order_id),
        )
    except ClientError as err:
        if err.response["Error"]["Code"] != "TransactionCanceledException":
            raise
        return _result(_load(order_id))
    metrics.add_metric(name="StockReleased", unit=MetricUnit.Count, value=1)
    return _result({**order, "status": "REJECTED"})


def _transition(order_id: str, new_status: str, expected: str, reason: str | None) -> dict:
    try:
        client.transact_write_items(
            TransactItems=[_order_update(order_id, new_status, expected, reason)]
        )
    except ClientError as err:
        if err.response["Error"]["Code"] != "TransactionCanceledException":
            raise
        order = _load(order_id)
        if order["status"] == new_status:
            return _result(order)  # a retry or a duplicate execution got here first
        raise ValueError(f"order is {order['status']}, expected {expected}") from err
    return _result({**_load(order_id)})


def reject(order_id: str, reason: str) -> dict[str, Any]:
    """Reject an order that never reserved stock (for example, out of stock)."""
    metrics.add_metric(name="OrdersRejected", unit=MetricUnit.Count, value=1)
    return _transition(order_id, "REJECTED", "PENDING", reason)


def confirm(order_id: str) -> dict[str, Any]:
    result = _transition(order_id, "CONFIRMED", "RESERVED", None)
    metrics.add_metric(name="OrdersConfirmed", unit=MetricUnit.Count, value=1)
    return result


@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics
def lambda_handler(event: dict[str, Any], context: LambdaContext) -> dict[str, Any]:
    action, order_id = event["action"], event["order_id"]
    logger.append_keys(order_id=order_id, action=action)
    if action == "reserve":
        return reserve(order_id)
    if action == "charge":
        return charge(order_id)
    if action == "release":
        return release(order_id, event.get("reason", "PAYMENT_FAILED"))
    if action == "reject":
        return reject(order_id, event.get("reason", "REJECTED"))
    if action == "confirm":
        return confirm(order_id)
    raise ValueError(f"unknown action: {action}")
