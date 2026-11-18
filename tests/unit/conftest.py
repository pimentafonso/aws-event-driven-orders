"""Run the real handler against DynamoDB tables mocked by moto."""

from __future__ import annotations

import importlib
import json
import sys
from dataclasses import dataclass
from typing import Any

import boto3
import pytest
from moto import mock_aws

ORDERS_TABLE = "aedo-test-orders"
IDEMPOTENCY_TABLE = "aedo-test-idempotency"


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AWS_DEFAULT_REGION", "eu-west-1")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.delenv("AWS_PROFILE", raising=False)
    monkeypatch.setenv("ORDERS_TABLE", ORDERS_TABLE)
    monkeypatch.setenv("IDEMPOTENCY_TABLE", IDEMPOTENCY_TABLE)
    monkeypatch.setenv("POWERTOOLS_SERVICE_NAME", "orders-api")
    monkeypatch.setenv("POWERTOOLS_METRICS_NAMESPACE", "aedo-test")
    monkeypatch.setenv("POWERTOOLS_TRACE_DISABLED", "true")


@pytest.fixture
def tables() -> Any:
    with mock_aws():
        ddb = boto3.resource("dynamodb")
        orders = ddb.create_table(
            TableName=ORDERS_TABLE,
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        idempotency = ddb.create_table(
            TableName=IDEMPOTENCY_TABLE,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        yield {"orders": orders, "idempotency": idempotency}


@pytest.fixture
def app(tables: Any) -> Any:
    """Import the handler inside the mock, so its boto3 clients talk to moto."""
    sys.modules.pop("orders_api.app", None)
    return importlib.import_module("orders_api.app")


@dataclass
class FakeContext:
    function_name: str = "aedo-test-orders-api"
    memory_limit_in_mb: int = 256
    invoked_function_arn: str = "arn:aws:lambda:eu-west-1:123456789012:function:aedo-test"
    aws_request_id: str = "req-1"

    def get_remaining_time_in_millis(self) -> int:
        return 10_000


def http_event(
    method: str,
    path: str,
    body: Any = None,
    headers: dict[str, str] | None = None,
    raw_body: str | None = None,
) -> dict[str, Any]:
    """A minimal API Gateway HTTP API (payload 2.0) event."""
    if raw_body is None and body is not None:
        raw_body = json.dumps(body)
    return {
        "version": "2.0",
        "routeKey": f"{method} {path}",
        "rawPath": path,
        "rawQueryString": "",
        "headers": {"content-type": "application/json", **(headers or {})},
        "requestContext": {
            "http": {"method": method, "path": path, "sourceIp": "127.0.0.1"},
            "requestId": "api-req-1",
            "stage": "$default",
        },
        "body": raw_body,
        "isBase64Encoded": False,
    }


def call(app: Any, event: dict[str, Any]) -> tuple[int, dict[str, Any], dict[str, str]]:
    response = app.lambda_handler(event, FakeContext())
    body = json.loads(response["body"]) if response.get("body") else {}
    return response["statusCode"], body, response.get("headers", {})


def fresh_import(name: str) -> Any:
    """Import a handler module inside the moto mock, discarding any earlier copy."""
    sys.modules.pop(name, None)
    return importlib.import_module(name)


@pytest.fixture
def steps(tables: Any) -> Any:
    return fresh_import("saga.steps")


@pytest.fixture
def notifier(tables: Any) -> Any:
    return fresh_import("notifier.handler")


def put_stock(tables: Any, sku: str, available: int) -> None:
    tables["orders"].put_item(Item={"pk": f"PRODUCT#{sku}", "sk": "STOCK", "available": available})


def stock(tables: Any, sku: str) -> int:
    return int(
        tables["orders"].get_item(Key={"pk": f"PRODUCT#{sku}", "sk": "STOCK"})["Item"]["available"]
    )


def put_order(
    tables: Any,
    order_id: str,
    items: list[dict[str, Any]],
    customer_id: str = "c-1",
    status: str = "PENDING",
) -> None:
    tables["orders"].put_item(
        Item={
            "pk": f"ORDER#{order_id}",
            "sk": "ORDER",
            "order_id": order_id,
            "customer_id": customer_id,
            "status": status,
            "items": items,
            "created_at": "2026-11-18T00:00:00.000+00:00",
        }
    )


def order(tables: Any, order_id: str) -> dict[str, Any]:
    return tables["orders"].get_item(Key={"pk": f"ORDER#{order_id}", "sk": "ORDER"})["Item"]
