"""End-to-end test of the deployed event flow and saga.

Usage:
    python scripts/e2e_saga.py <api-endpoint> [--poison <queue-url> <dlq-url>]

Places three orders through the API and follows each to its final status:

    happy path      -> CONFIRMED, stock taken, notification recorded
    declined card   -> REJECTED (PAYMENT_DECLINED), stock given back
    too many units  -> REJECTED (OUT_OF_STOCK), stock untouched

It prints the time from the API's 201 to the final status for each order.
With --poison it also sends a malformed message to the notification queue and
waits until it reaches the dead-letter queue (three receives, a few minutes).

Run scripts/seed_stock.py first. Uses the default AWS credential chain; reads
the orders table directly to check stock and notifications.
"""

from __future__ import annotations

import sys
import time
import uuid
from typing import Any

import boto3
from smoke_api import request

TABLE = "aedo-dev-orders"
FINAL = {"CONFIRMED", "REJECTED"}

dynamodb = boto3.resource("dynamodb", region_name="eu-west-1")
table = dynamodb.Table(TABLE)


def stock(sku: str) -> int:
    item = table.get_item(Key={"pk": f"PRODUCT#{sku}", "sk": "STOCK"}, ConsistentRead=True)
    return int(item["Item"]["available"])


def place(endpoint: str, customer_id: str, items: list[dict[str, Any]]) -> tuple[str, float]:
    body = {"customer_id": customer_id, "items": items}
    status, payload, _ = request(
        endpoint, "POST", "/orders", body, {"idempotency-key": f"e2e-{uuid.uuid4()}"}
    )
    if status != 201:
        raise SystemExit(f"create failed: {status} {payload}")
    return payload["order_id"], time.perf_counter()


def wait_final(endpoint: str, order_id: str, started: float) -> tuple[dict[str, Any], float]:
    deadline = started + 60
    while time.perf_counter() < deadline:
        status, payload, _ = request(endpoint, "GET", f"/orders/{order_id}")
        if status == 200 and payload["status"] in FINAL:
            return payload, time.perf_counter() - started
        time.sleep(0.25)
    raise SystemExit(f"order {order_id} did not finish within 60 s")


def wait_notification(order_id: str, timeout: float = 30) -> float | None:
    start = time.perf_counter()
    while time.perf_counter() - start < timeout:
        key = {"pk": f"ORDER#{order_id}", "sk": "NOTIFICATION"}
        if "Item" in table.get_item(Key=key, ConsistentRead=True):
            return time.perf_counter() - start
        time.sleep(0.25)
    return None


def poison(queue_url: str, dlq_url: str) -> bool:
    sqs = boto3.client("sqs", region_name="eu-west-1")

    def dlq_depth() -> int:
        attrs = sqs.get_queue_attributes(
            QueueUrl=dlq_url, AttributeNames=["ApproximateNumberOfMessages"]
        )
        return int(attrs["Attributes"]["ApproximateNumberOfMessages"])

    before = dlq_depth()
    sqs.send_message(QueueUrl=queue_url, MessageBody="{not an event")
    start = time.perf_counter()
    print("      poison message sent; waiting for the dead-letter queue (up to 6 min)...")
    while time.perf_counter() - start < 360:
        if dlq_depth() > before:
            print(f"PASS  poison message reached the DLQ after {time.perf_counter() - start:.0f} s")
            return True
        time.sleep(10)
    print("FAIL  poison message did not reach the DLQ within 6 min")
    return False


def main() -> int:
    if len(sys.argv) < 2 or not sys.argv[1].startswith("https://"):
        print(__doc__)
        return 2
    endpoint = sys.argv[1]
    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {name}{f' ({detail})' if detail else ''}")

    sku1, sku5 = stock("SKU-1"), stock("SKU-5")

    happy_id, t0 = place(endpoint, "e2e", [{"sku": "SKU-1", "quantity": 1}])
    declined_id, t1 = place(endpoint, "declined-e2e", [{"sku": "SKU-1", "quantity": 2}])
    big_id, t2 = place(endpoint, "e2e", [{"sku": "SKU-5", "quantity": sku5 + 1}])

    happy, happy_s = wait_final(endpoint, happy_id, t0)
    declined, declined_s = wait_final(endpoint, declined_id, t1)
    big, big_s = wait_final(endpoint, big_id, t2)

    check("happy path confirmed", happy["status"] == "CONFIRMED", f"{happy_s:.2f} s")
    check(
        "declined payment rejected",
        (declined["status"], declined.get("reason")) == ("REJECTED", "PAYMENT_DECLINED"),
        f"{declined_s:.2f} s",
    )
    check(
        "too many units rejected",
        (big["status"], big.get("reason")) == ("REJECTED", "OUT_OF_STOCK"),
        f"{big_s:.2f} s",
    )
    check("stock: only the confirmed unit was taken", stock("SKU-1") == sku1 - 1)
    check("stock: out-of-stock order took nothing", stock("SKU-5") == sku5)

    notified_s = wait_notification(happy_id)
    check(
        "notification recorded for the confirmed order",
        notified_s is not None,
        f"{notified_s:.2f} s after confirmation was seen" if notified_s is not None else "",
    )
    check("no notification for a rejected order", wait_notification(declined_id, 5) is None)

    if "--poison" in sys.argv:
        i = sys.argv.index("--poison")
        check("dead-letter queue", poison(sys.argv[i + 1], sys.argv[i + 2]))

    print("All checks passed." if failures == 0 else f"{failures} check(s) failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
