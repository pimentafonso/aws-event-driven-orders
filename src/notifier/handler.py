"""SQS consumer for OrderConfirmed events.

Each message body is an EventBridge event. The consumer records a NOTIFICATION
item per order with a conditional write, so a duplicate delivery is detected
and skipped instead of notifying the customer twice.

Failures are reported per message (partial batch response): one bad message is
retried on its own, and after three receives SQS moves it to the dead-letter
queue, while the rest of the batch succeeds.

Each notification also records when the event was published, when it reached
the queue and when Lambda first received it, so the time from OrderConfirmed
to the notification can be split by hop (NotificationLatency metric).
"""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.batch import (
    BatchProcessor,
    EventType,
    process_partial_response,
)
from aws_lambda_powertools.utilities.data_classes.sqs_event import SQSRecord
from aws_lambda_powertools.utilities.typing import LambdaContext
from botocore.exceptions import ClientError

import faults

logger = Logger()
tracer = Tracer()
metrics = Metrics()
# Report every failed message, even when the whole batch failed, instead of
# failing the invocation: the dead-letter queue handles bad messages, and the
# notifier-errors alarm is kept for failures of the function itself.
processor = BatchProcessor(event_type=EventType.SQS, raise_on_entire_batch_failure=False)

table = boto3.resource("dynamodb").Table(os.environ["ORDERS_TABLE"])


class InvalidMessageError(ValueError):
    """The message is not an OrderConfirmed event."""


class InjectedFailureError(RuntimeError):
    """A failure injected through the fault switch (faults.py)."""


def parse(body: str) -> dict[str, str]:
    try:
        event = json.loads(body)
        detail = event["detail"]
        order_id, customer_id = detail["order_id"], detail["customer_id"]
    except (ValueError, KeyError, TypeError) as err:
        raise InvalidMessageError("not an OrderConfirmed event") from err
    if event.get("detail-type") != "OrderConfirmed":
        raise InvalidMessageError(f"unexpected detail-type {event.get('detail-type')!r}")
    return {
        "order_id": str(order_id),
        "customer_id": str(customer_id),
        "event_time": str(event.get("time", "")),
    }


def _ms(value: datetime) -> int:
    return int(value.timestamp() * 1000)


def timings(record: SQSRecord, event_time: str, now: datetime) -> dict[str, int]:
    """Milliseconds spent on each hop between OrderConfirmed and now.

    EventBridge's event time has one-second resolution, so the first hop
    (bus to queue) can read up to a second long or short.
    """
    sent = int(record.attributes.sent_timestamp)
    received = int(record.attributes.approximate_first_receive_timestamp)
    result = {
        "queue_wait_ms": received - sent,
        "handler_ms": _ms(now) - received,
    }
    if event_time:
        published = _ms(datetime.fromisoformat(event_time.replace("Z", "+00:00")))
        result["bus_to_queue_ms"] = sent - published
        result["total_ms"] = _ms(now) - published
    return result


@tracer.capture_method
def record_handler(record: SQSRecord) -> None:
    message = parse(record.body)
    if faults.should_fail(faults.NOTIFIER_FAILURE):
        raise InjectedFailureError("notification failed (injected)")
    now = datetime.now(UTC)
    hops = timings(record, message.pop("event_time"), now)
    try:
        table.put_item(
            Item={
                "pk": f"ORDER#{message['order_id']}",
                "sk": "NOTIFICATION",
                "customer_id": message["customer_id"],
                "channel": "email (simulated)",
                "sent_at": now.isoformat(timespec="milliseconds"),
                "message_id": record.message_id,
                "receive_count": int(record.attributes.approximate_receive_count),
                "timings": hops,
            },
            ConditionExpression="attribute_not_exists(pk)",
        )
    except ClientError as err:
        if err.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        logger.info("duplicate delivery skipped", extra=message)
        metrics.add_metric(name="DuplicateNotificationsSkipped", unit=MetricUnit.Count, value=1)
        return
    logger.info("notification sent", extra={**message, **hops})
    metrics.add_metric(name="NotificationsSent", unit=MetricUnit.Count, value=1)
    if "total_ms" in hops:
        metrics.add_metric(
            name="NotificationLatency", unit=MetricUnit.Milliseconds, value=hops["total_ms"]
        )


@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics
def lambda_handler(event: dict[str, Any], context: LambdaContext) -> dict[str, Any]:
    return process_partial_response(
        event=event, record_handler=record_handler, processor=processor, context=context
    )
