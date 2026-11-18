"""Lambda handler behind the HTTP API.

POST /orders              create an order; needs an Idempotency-Key header
GET  /orders/{order_id}   read an order
"""

from __future__ import annotations

import os
import uuid
from datetime import UTC, datetime
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.event_handler import APIGatewayHttpResolver, Response, content_types
from aws_lambda_powertools.event_handler.exceptions import BadRequestError, NotFoundError
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.idempotency import (
    DynamoDBPersistenceLayer,
    IdempotencyConfig,
    idempotent_function,
)
from aws_lambda_powertools.utilities.idempotency.exceptions import (
    IdempotencyAlreadyInProgressError,
    IdempotencyValidationError,
)
from aws_lambda_powertools.utilities.typing import LambdaContext

from orders_api.validation import IDEMPOTENCY_KEY, InvalidOrderError, parse_new_order

logger = Logger()
tracer = Tracer()
metrics = Metrics()
app = APIGatewayHttpResolver()

orders_table = boto3.resource("dynamodb").Table(os.environ["ORDERS_TABLE"])

# The idempotency record is keyed on the client's Idempotency-Key. Its stored
# payload hash covers the order itself, so reusing a key with a different body
# is rejected instead of silently returning the first order.
idempotency_config = IdempotencyConfig(
    event_key_jmespath="key",
    payload_validation_jmespath="order",
    expires_after_seconds=24 * 60 * 60,
)
persistence = DynamoDBPersistenceLayer(table_name=os.environ["IDEMPOTENCY_TABLE"])


def _json_error(status: int, message: str) -> Response:
    return Response(
        status_code=status,
        content_type=content_types.APPLICATION_JSON,
        body={"message": message},
    )


def _to_api(item: dict[str, Any]) -> dict[str, Any]:
    order = {
        "order_id": item["pk"].removeprefix("ORDER#"),
        "status": item["status"],
        "customer_id": item["customer_id"],
        # DynamoDB returns numbers as Decimal; quantities are whole numbers.
        "items": [{"sku": i["sku"], "quantity": int(i["quantity"])} for i in item["items"]],
        "created_at": item["created_at"],
    }
    # Set by the saga when it rejects an order (OUT_OF_STOCK, PAYMENT_DECLINED...).
    if "reason" in item:
        order["reason"] = item["reason"]
    return order


@idempotent_function(
    data_keyword_argument="request",
    config=idempotency_config,
    persistence_store=persistence,
)
def create_order(request: dict[str, Any]) -> dict[str, Any]:
    """Store a new order. Runs once per Idempotency-Key; replays get the same result."""
    order = request["order"]
    order_id = str(uuid.uuid4())
    item = {
        "pk": f"ORDER#{order_id}",
        "sk": "ORDER",
        # Stored on its own too, so the stream event carries it as-is.
        "order_id": order_id,
        "status": "PENDING",
        "customer_id": order["customer_id"],
        "items": order["items"],
        "created_at": datetime.now(UTC).isoformat(timespec="milliseconds"),
    }
    orders_table.put_item(Item=item, ConditionExpression="attribute_not_exists(pk)")
    metrics.add_metric(name="OrdersCreated", unit=MetricUnit.Count, value=1)
    return _to_api(item)


@app.post("/orders")
@tracer.capture_method
def post_order() -> Response:
    key = app.current_event.headers.get("idempotency-key")
    if key is None:
        raise BadRequestError("Idempotency-Key header is required")
    if not IDEMPOTENCY_KEY.match(key):
        raise BadRequestError("Idempotency-Key must be 8-128 printable ASCII characters")

    try:
        order = parse_new_order(app.current_event.json_body)
    except InvalidOrderError as err:
        raise BadRequestError(str(err)) from err
    except ValueError as err:  # the body is not JSON
        raise BadRequestError("body must be valid JSON") from err

    try:
        result = create_order(request={"key": key, "order": order})
    except IdempotencyValidationError:
        return _json_error(422, "Idempotency-Key was already used with a different order")
    except IdempotencyAlreadyInProgressError:
        return _json_error(409, "a request with this Idempotency-Key is still in progress")

    return Response(
        status_code=201,
        content_type=content_types.APPLICATION_JSON,
        body=result,
        headers={"Location": f"/orders/{result['order_id']}"},
    )


@app.get("/orders/<order_id>")
@tracer.capture_method
def get_order(order_id: str) -> dict[str, Any]:
    try:
        uuid.UUID(order_id)
    except ValueError as err:
        raise NotFoundError("order not found") from err
    item = orders_table.get_item(Key={"pk": f"ORDER#{order_id}", "sk": "ORDER"}).get("Item")
    if item is None:
        raise NotFoundError("order not found")
    return _to_api(item)


@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics
def lambda_handler(event: dict[str, Any], context: LambdaContext) -> dict[str, Any]:
    idempotency_config.register_lambda_context(context)
    return app.resolve(event, context)
