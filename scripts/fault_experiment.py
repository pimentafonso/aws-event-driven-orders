"""Fault-injection experiment against the deployed dev stack.

Usage:
    python scripts/fault_experiment.py <api-endpoint>
        [--orders 20] [--payment-rate 0.5] [--notifier-rate 0.5]

Turns on the fault switch (/aedo-dev/faults), places orders through the API
and checks that the system stays correct while steps fail:

- The payment provider is "down" for a share of calls. The saga retries the
  charge up to 3 times; an order whose 4 attempts all fail is rejected as
  PAYMENT_FAILED and its stock is given back.
- The notifier fails a share of messages. SQS delivers them again; a message
  that fails 3 times moves to the dead-letter queue.

Checks: every order ends CONFIRMED or REJECTED, no saga execution fails, stock
taken equals the confirmed orders, and every confirmed order is either
notified or in the dead-letter queue. The switch is reset to 0 at the end, even
on failure. Afterwards, `bash scripts/redrive_dlq.sh` delivers what reached the
dead-letter queue.

Needs an administrator profile: it writes the parameter and reads the saga's
execution history. Prints counts and timings only.
"""

from __future__ import annotations

import argparse
import json
import time
import uuid
from collections import Counter
from datetime import UTC, datetime, timedelta
from typing import Any

import boto3
from smoke_api import request

REGION = "eu-west-1"
PREFIX = "aedo-dev"
PARAMETER = f"/{PREFIX}/faults"
SKU, START_STOCK = "SKU-1", 100
SWITCH_DELAY_S = 15  # the functions cache the switch for 10 s

session = boto3.Session(region_name=REGION)
ssm = session.client("ssm")
sqs = session.client("sqs")
sfn = session.client("stepfunctions")
table = session.resource("dynamodb").Table(f"{PREFIX}-orders")


def set_switch(payment: float, notifier: float) -> None:
    value = {"payment_unavailable_rate": payment, "notifier_failure_rate": notifier}
    ssm.put_parameter(Name=PARAMETER, Value=json.dumps(value), Type="String", Overwrite=True)


def get(pk: str, sk: str) -> dict[str, Any] | None:
    return table.get_item(Key={"pk": pk, "sk": sk}, ConsistentRead=True).get("Item")


def dlq_order_ids(url: str) -> set[str]:
    """Order IDs of the OrderConfirmed events in the dead-letter queue.

    Counts from the messages themselves: SQS's message counts are approximate
    and can lag by minutes. Each read hides what it returned for 2 seconds, so
    the next read returns other messages; nothing consumes this queue, so they
    stay ready for a redrive. Long polling makes each call query every server.
    """
    found: set[str] = set()
    for _ in range(3):
        response = sqs.receive_message(
            QueueUrl=url, MaxNumberOfMessages=10, VisibilityTimeout=2, WaitTimeSeconds=1
        )
        for message in response.get("Messages", []):
            try:
                found.add(str(json.loads(message["Body"])["detail"]["order_id"]))
            except (ValueError, KeyError, TypeError):
                continue  # not an OrderConfirmed event
    return found


def place_orders(endpoint: str, count: int) -> list[str]:
    ids = []
    for i in range(count):
        body = {"customer_id": f"chaos-{i}", "items": [{"sku": SKU, "quantity": 1}]}
        status, payload, _ = request(
            endpoint, "POST", "/orders", body, {"idempotency-key": f"chaos-{uuid.uuid4()}"}
        )
        if status != 201:
            raise SystemExit(f"create failed: {status} {payload}")
        ids.append(payload["order_id"])
        time.sleep(0.3)  # stay well inside the account's 10 concurrent executions
    return ids


def wait_final(order_ids: list[str], timeout: float = 180) -> dict[str, dict[str, Any]]:
    final: dict[str, dict[str, Any]] = {}
    deadline = time.monotonic() + timeout
    while len(final) < len(order_ids) and time.monotonic() < deadline:
        for order_id in order_ids:
            if order_id not in final:
                item = get(f"ORDER#{order_id}", "ORDER")
                if item and item["status"] in ("CONFIRMED", "REJECTED"):
                    final[order_id] = item
        time.sleep(1)
    return final


def saga_history(since: datetime) -> tuple[Counter[str], Counter[int]]:
    """Execution statuses, and how many injected faults each execution hit."""
    account = session.client("sts").get_caller_identity()["Account"]
    arn = f"arn:aws:states:{REGION}:{account}:stateMachine:{PREFIX}-order-saga"
    statuses: Counter[str] = Counter()
    faults_per_execution: Counter[int] = Counter()
    for page in sfn.get_paginator("list_executions").paginate(stateMachineArn=arn):
        recent = [e for e in page["executions"] if e["startDate"] >= since]
        for execution in recent:
            statuses[execution["status"]] += 1
            events = sfn.get_execution_history(
                executionArn=execution["executionArn"], maxResults=1000
            )["events"]
            faults = sum(
                1
                for e in events
                if e.get("taskFailedEventDetails", {}).get("error")
                == "PaymentProviderUnavailableError"
            )
            faults_per_execution[faults] += 1
        if len(recent) < len(page["executions"]):
            break
    return statuses, faults_per_execution


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("endpoint")
    parser.add_argument("--orders", type=int, default=20)
    parser.add_argument("--payment-rate", type=float, default=0.5)
    parser.add_argument("--notifier-rate", type=float, default=0.5)
    args = parser.parse_args()
    if not args.endpoint.startswith("https://"):
        raise SystemExit("the endpoint must start with https://")

    dlq_url = sqs.get_queue_url(QueueName=f"{PREFIX}-notifications-dlq")["QueueUrl"]
    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {name}{f' ({detail})' if detail else ''}")

    table.put_item(Item={"pk": f"PRODUCT#{SKU}", "sk": "STOCK", "available": START_STOCK})
    print(
        f"Fault switch: payment unavailable {args.payment_rate:.0%}, "
        f"notifier failure {args.notifier_rate:.0%}; {args.orders} orders"
    )
    try:
        set_switch(args.payment_rate, args.notifier_rate)
        time.sleep(SWITCH_DELAY_S)
        since = datetime.now(UTC) - timedelta(seconds=5)
        started = time.monotonic()
        order_ids = place_orders(args.endpoint, args.orders)

        final = wait_final(order_ids)
        print(f"      all orders final after {time.monotonic() - started:.0f} s")
        outcomes = Counter(
            f"{o['status']}" + (f" ({o['reason']})" if o.get("reason") else "")
            for o in final.values()
        )
        confirmed = [i for i, o in final.items() if o["status"] == "CONFIRMED"]
        check("every order reached a final status", len(final) == len(order_ids))
        check(
            "rejections are payment failures only",
            set(outcomes) <= {"CONFIRMED", "REJECTED (PAYMENT_FAILED)"},
            ", ".join(f"{k}: {v}" for k, v in sorted(outcomes.items())),
        )
        available = int(get(f"PRODUCT#{SKU}", "STOCK")["available"])
        check(
            "stock taken equals confirmed orders",
            START_STOCK - available == len(confirmed),
            f"{START_STOCK - available} taken, {len(confirmed)} confirmed",
        )

        statuses, faults = saga_history(since)
        check("no saga execution failed", set(statuses) == {"SUCCEEDED"}, str(dict(statuses)))
        print(
            "      injected payment faults per execution: "
            + ", ".join(f"{n} fault(s): {c}" for n, c in sorted(faults.items()))
        )

        # Notifications: failed messages come back after the 60 s visibility
        # timeout, so the last ones can take about three minutes.
        deadline = time.monotonic() + 360
        notified: dict[str, dict[str, Any]] = {}
        dead: set[str] = set()
        while time.monotonic() < deadline:
            for order_id in confirmed:
                if order_id not in notified:
                    item = get(f"ORDER#{order_id}", "NOTIFICATION")
                    if item:
                        notified[order_id] = item
            dead = dlq_order_ids(dlq_url) & set(confirmed)
            if len(notified) + len(dead) >= len(confirmed):
                break
            time.sleep(10)
        print(f"      notifications settled after {time.monotonic() - started:.0f} s")
        receives = Counter(int(n.get("receive_count", 1)) for n in notified.values())
        check(
            "every confirmed order notified or dead-lettered, never both",
            set(notified) | dead == set(confirmed) and not set(notified) & dead,
            f"{len(notified)} notified, {len(dead)} in the DLQ",
        )
        print(
            "      notifications by receive count: "
            + ", ".join(f"{k}: {v}" for k, v in sorted(receives.items()))
        )
    finally:
        set_switch(0, 0)
        print("      fault switch reset to 0")

    print("All checks passed." if failures == 0 else f"{failures} check(s) failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
