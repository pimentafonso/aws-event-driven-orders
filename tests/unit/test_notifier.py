from __future__ import annotations

import json
from typing import Any

from .conftest import FakeContext


def sqs_record(message_id: str, body: str) -> dict[str, Any]:
    return {
        "messageId": message_id,
        "receiptHandle": f"handle-{message_id}",
        "body": body,
        "attributes": {"ApproximateReceiveCount": "1"},
        "messageAttributes": {},
        "md5OfBody": "",
        "eventSource": "aws:sqs",
        "eventSourceARN": "arn:aws:sqs:eu-west-1:123456789012:aedo-test-notifications",
        "awsRegion": "eu-west-1",
    }


def confirmed(order_id: str, customer_id: str = "c-1") -> str:
    return json.dumps(
        {
            "source": "aedo.orders",
            "detail-type": "OrderConfirmed",
            "detail": {"order_id": order_id, "customer_id": customer_id},
        }
    )


def handle(notifier: Any, *records: dict[str, Any]) -> dict[str, Any]:
    return notifier.lambda_handler({"Records": list(records)}, FakeContext())


def notifications(tables: Any) -> list[dict[str, Any]]:
    items = tables["orders"].scan()["Items"]
    return [i for i in items if i["sk"] == "NOTIFICATION"]


def test_a_confirmed_order_is_notified_once(notifier: Any, tables: Any) -> None:
    response = handle(notifier, sqs_record("m1", confirmed("o-1")))

    assert response == {"batchItemFailures": []}
    assert [n["pk"] for n in notifications(tables)] == ["ORDER#o-1"]


def test_duplicate_delivery_is_skipped(notifier: Any, tables: Any) -> None:
    handle(notifier, sqs_record("m1", confirmed("o-1")))
    response = handle(notifier, sqs_record("m2", confirmed("o-1")))

    assert response == {"batchItemFailures": []}
    assert len(notifications(tables)) == 1
    assert notifications(tables)[0]["message_id"] == "m1"


def test_a_bad_message_fails_alone(notifier: Any, tables: Any) -> None:
    response = handle(
        notifier,
        sqs_record("m1", confirmed("o-1")),
        sqs_record("m2", "{not json"),
        sqs_record("m3", json.dumps({"detail-type": "OrderPlaced", "detail": {}})),
        sqs_record("m4", confirmed("o-2")),
    )

    assert response == {"batchItemFailures": [{"itemIdentifier": "m2"}, {"itemIdentifier": "m3"}]}
    assert sorted(n["pk"] for n in notifications(tables)) == ["ORDER#o-1", "ORDER#o-2"]
