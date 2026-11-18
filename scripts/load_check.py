"""Check a load-test run and collect its measurements.

Usage:
    python scripts/load_check.py <run-id> [--start-stock 100000] [--out FILE]

Run it after `scripts/load/orders.js` finishes, with the same run ID and the
stock that `seed_stock.py` set before the run. It waits for every order of the
run (customer ID "load-<run-id>") to reach a final status, then checks:

- every order is CONFIRMED (stock is high enough that none should be rejected),
- the stock taken from each product equals the quantity confirmed for it,
- every confirmed order has exactly one notification,
- no saga execution failed, timed out or was aborted,
- both dead-letter queues are empty.

It then reads, for the run's time window, the saga duration, the API latency,
the peak account concurrency, throttles and the notification queue's age from
CloudWatch, and the notification timings stored with each order. Everything
goes to stdout and, with --out, to a JSON file for the write-up.

Needs an administrator profile: it scans the table and reads execution history.
Prints counts and timings only.
"""

from __future__ import annotations

import argparse
import json
import math
import time
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from typing import Any

import boto3
from boto3.dynamodb.conditions import Attr

REGION = "eu-west-1"
PREFIX = "aedo-dev"
SKUS = [f"SKU-{n}" for n in range(1, 6)]
FINAL = ("CONFIRMED", "REJECTED")
METRICS_DELAY_S = 180

session = boto3.Session(region_name=REGION)
table = session.resource("dynamodb").Table(f"{PREFIX}-orders")
sqs = session.client("sqs")
sfn = session.client("stepfunctions")
cloudwatch = session.client("cloudwatch")


def scan_run(run_id: str) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    """The run's ORDER items and their NOTIFICATION items, by order ID."""
    orders: dict[str, dict[str, Any]] = {}
    notifications: dict[str, dict[str, Any]] = {}
    customer = f"load-{run_id}"
    kwargs: dict[str, Any] = {
        "FilterExpression": Attr("sk").is_in(["ORDER", "NOTIFICATION"]),
    }
    raw_notifications: dict[str, dict[str, Any]] = {}
    while True:
        page = table.scan(**kwargs)
        for item in page["Items"]:
            order_id = str(item["pk"]).removeprefix("ORDER#")
            if item["sk"] == "ORDER" and item.get("customer_id") == customer:
                orders[order_id] = item
            elif item["sk"] == "NOTIFICATION":
                raw_notifications[order_id] = item
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
    for order_id in orders:
        if order_id in raw_notifications:
            notifications[order_id] = raw_notifications[order_id]
    return orders, notifications


def queue_has_messages(name: str) -> bool:
    """Reads the queue itself: SQS's message counts are approximate and lag."""
    url = sqs.get_queue_url(QueueName=name)["QueueUrl"]
    for _ in range(3):
        response = sqs.receive_message(
            QueueUrl=url, MaxNumberOfMessages=1, VisibilityTimeout=2, WaitTimeSeconds=1
        )
        if response.get("Messages"):
            return True
    return False


def failed_executions(since: datetime) -> int:
    account = session.client("sts").get_caller_identity()["Account"]
    arn = f"arn:aws:states:{REGION}:{account}:stateMachine:{PREFIX}-order-saga"
    count = 0
    for status in ("FAILED", "TIMED_OUT", "ABORTED"):
        pages = sfn.get_paginator("list_executions").paginate(
            stateMachineArn=arn, statusFilter=status
        )
        for page in pages:
            count += sum(1 for e in page["executions"] if e["startDate"] >= since)
    return count


def percentile(values: list[float], p: float) -> float:
    ordered = sorted(values)
    index = max(0, math.ceil(p / 100 * len(ordered)) - 1)
    return ordered[index]


def metric(namespace: str, name: str, dimensions: dict[str, str], stat: str) -> dict[str, Any]:
    return {
        "Namespace": namespace,
        "MetricName": name,
        "Dimensions": [{"Name": k, "Value": v} for k, v in dimensions.items()],
        "Stat": stat,
    }


def cloudwatch_figures(start: datetime, end: datetime) -> dict[str, float | None]:
    """One figure per metric over the run's window."""
    account = session.client("sts").get_caller_identity()["Account"]
    machine = f"arn:aws:states:{REGION}:{account}:stateMachine:{PREFIX}-order-saga"
    api_id = next(
        a["ApiId"]
        for a in session.client("apigatewayv2").get_apis()["Items"]
        if a["Name"] == f"{PREFIX}-orders"
    )
    start = start.replace(second=0, microsecond=0)
    end = end.replace(second=0, microsecond=0) + timedelta(minutes=2)
    window = int((end - start).total_seconds())
    # (label, metric, period): the whole window for distributions and sums,
    # one minute for peaks.
    queries: list[tuple[str, dict[str, Any], int]] = []
    for stat in ("p50", "p95", "p99", "Maximum"):
        queries.append(
            (
                f"saga_duration_ms_{stat.lower()}",
                metric("AWS/States", "ExecutionTime", {"StateMachineArn": machine}, stat),
                window,
            )
        )
        queries.append(
            (
                f"api_latency_ms_{stat.lower()}",
                metric("AWS/ApiGateway", "Latency", {"ApiId": api_id}, stat),
                window,
            )
        )
    queries += [
        (
            "saga_executions_started",
            metric("AWS/States", "ExecutionsStarted", {"StateMachineArn": machine}, "Sum"),
            window,
        ),
        (
            "saga_execution_throttled",
            metric("AWS/States", "ExecutionThrottled", {"StateMachineArn": machine}, "Sum"),
            window,
        ),
        ("api_requests", metric("AWS/ApiGateway", "Count", {"ApiId": api_id}, "Sum"), window),
        ("api_4xx", metric("AWS/ApiGateway", "4xx", {"ApiId": api_id}, "Sum"), window),
        ("api_5xx", metric("AWS/ApiGateway", "5xx", {"ApiId": api_id}, "Sum"), window),
        ("lambda_throttles", metric("AWS/Lambda", "Throttles", {}, "Sum"), window),
        ("lambda_errors", metric("AWS/Lambda", "Errors", {}, "Sum"), window),
        (
            "lambda_peak_concurrency",
            metric("AWS/Lambda", "ConcurrentExecutions", {}, "Maximum"),
            60,
        ),
        (
            "notifications_oldest_message_s_max",
            metric(
                "AWS/SQS",
                "ApproximateAgeOfOldestMessage",
                {"QueueName": f"{PREFIX}-notifications"},
                "Maximum",
            ),
            60,
        ),
        (
            "pipe_failures",
            metric(
                "AWS/EventBridge/Pipes",
                "ExecutionFailed",
                {"PipeName": f"{PREFIX}-orders-placed"},
                "Sum",
            ),
            window,
        ),
    ]
    response = cloudwatch.get_metric_data(
        MetricDataQueries=[
            {
                "Id": f"m{i}",
                "Label": label,
                "MetricStat": {
                    "Metric": {k: v for k, v in m.items() if k != "Stat"},
                    "Period": period,
                    "Stat": m["Stat"],
                },
            }
            for i, (label, m, period) in enumerate(queries)
        ],
        StartTime=start,
        EndTime=end,
    )
    figures: dict[str, float | None] = {}
    for result in response["MetricDataResults"]:
        values = result["Values"]
        label = result["Label"]
        if not values:
            figures[label] = None
        elif label.endswith(("_max", "maximum", "concurrency")):
            figures[label] = round(max(values), 1)
        else:
            figures[label] = round(sum(values), 1)
    return figures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("run_id")
    parser.add_argument("--start-stock", type=int, default=100_000)
    parser.add_argument("--timeout", type=int, default=600, help="seconds to wait")
    parser.add_argument("--out", help="write the results as JSON to this file")
    args = parser.parse_args()

    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {name}{f' ({detail})' if detail else ''}")

    deadline = time.monotonic() + args.timeout
    while True:
        orders, notifications = scan_run(args.run_id)
        final = {i: o for i, o in orders.items() if o["status"] in FINAL}
        confirmed = [i for i, o in final.items() if o["status"] == "CONFIRMED"]
        settled = len(final) == len(orders) and set(confirmed) <= set(notifications)
        if (orders and settled) or time.monotonic() > deadline:
            break
        print(f"      {len(final)}/{len(orders)} final, {len(notifications)} notified; waiting")
        time.sleep(15)
    if not orders:
        raise SystemExit(f"no orders found for run {args.run_id}")

    statuses = Counter(
        o["status"] + (f" ({o['reason']})" if o.get("reason") else "") for o in orders.values()
    )
    check(f"{len(orders)} orders found, every one final", len(final) == len(orders))
    check(
        "every order confirmed",
        set(statuses) == {"CONFIRMED"},
        ", ".join(f"{k}: {v}" for k, v in sorted(statuses.items())),
    )

    ordered: defaultdict[str, int] = defaultdict(int)
    for order_id in confirmed:
        for item in orders[order_id]["items"]:
            ordered[str(item["sku"])] += int(item["quantity"])
    stock = {
        sku: int(
            table.get_item(Key={"pk": f"PRODUCT#{sku}", "sk": "STOCK"}, ConsistentRead=True)[
                "Item"
            ]["available"]
        )
        for sku in SKUS
    }
    taken = {sku: args.start_stock - stock[sku] for sku in SKUS}
    check(
        "stock taken equals confirmed quantity, per product",
        all(taken[sku] == ordered[sku] for sku in SKUS),
        ", ".join(f"{sku}: {taken[sku]}/{ordered[sku]}" for sku in SKUS),
    )
    check(
        "every confirmed order notified",
        set(confirmed) <= set(notifications),
        f"{len(set(confirmed) & set(notifications))} of {len(confirmed)}",
    )

    created = [datetime.fromisoformat(str(o["created_at"])) for o in orders.values()]
    start, end = min(created), max(created)
    check("no saga execution failed", (failed := failed_executions(start)) == 0, str(failed))
    for queue in (f"{PREFIX}-events-dlq", f"{PREFIX}-notifications-dlq"):
        check(f"{queue} is empty", not queue_has_messages(queue))

    results: dict[str, Any] = {
        "run_id": args.run_id,
        "orders": len(orders),
        "statuses": dict(statuses),
        "window_seconds": round((end - start).total_seconds()),
    }
    totals = [float(n["timings"]["total_ms"]) for n in notifications.values() if "timings" in n]
    if totals:
        results["notification_total_ms"] = {
            f"p{p}": round(percentile(totals, p)) for p in (50, 95, 99)
        } | {"max": round(max(totals))}
    receives = Counter(int(n.get("receive_count", 1)) for n in notifications.values())
    results["notification_receive_counts"] = {str(k): v for k, v in sorted(receives.items())}
    # CloudWatch publishes these one to three minutes late.
    ready = end + timedelta(seconds=METRICS_DELAY_S)
    wait = (ready - datetime.now(ready.tzinfo)).total_seconds()
    if wait > 0:
        print(f"      waiting {wait:.0f} s for CloudWatch to catch up")
        time.sleep(wait)
    results["cloudwatch"] = cloudwatch_figures(start, end)

    print(json.dumps(results, indent=2, default=str))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as file:
            json.dump(results, file, indent=2, default=str)
    print("All checks passed." if failures == 0 else f"{failures} check(s) failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
