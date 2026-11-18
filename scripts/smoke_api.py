"""Smoke-test the deployed orders API with SigV4-signed requests.

Usage:
    python scripts/smoke_api.py <api-endpoint>

Uses the default AWS credential chain (for example AWS_PROFILE). Exits non-zero
if any check fails. Prints status codes and latencies, never credentials.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request
import uuid
from typing import Any

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

REGION = "eu-west-1"


def request(
    endpoint: str,
    method: str,
    path: str,
    body: Any = None,
    headers: dict[str, str] | None = None,
    sign: bool = True,
) -> tuple[int, Any, float]:
    url = endpoint.rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    all_headers = {"content-type": "application/json", **(headers or {})}
    aws_request = AWSRequest(method=method, url=url, data=data, headers=all_headers)
    if sign:
        credentials = boto3.Session().get_credentials().get_frozen_credentials()
        SigV4Auth(credentials, "execute-api", REGION).add_auth(aws_request)
    # main() only accepts https:// endpoints, so no other URL scheme reaches here.
    prepared = urllib.request.Request(  # noqa: S310
        url, data=data, headers=dict(aws_request.headers), method=method
    )
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(prepared, timeout=15) as response:  # noqa: S310
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as err:
        status, raw = err.code, err.read()
    elapsed_ms = (time.perf_counter() - start) * 1000
    try:
        payload = json.loads(raw) if raw else None
    except ValueError:
        payload = raw.decode(errors="replace")
    return status, payload, elapsed_ms


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1].startswith("https://"):
        print(__doc__)
        return 2
    endpoint = sys.argv[1]
    order = {"customer_id": "smoke", "items": [{"sku": "SKU-1", "quantity": 1}]}
    key = f"smoke-{uuid.uuid4()}"
    failures = 0

    def check(name: str, expected: int, result: tuple[int, Any, float]) -> Any:
        nonlocal failures
        status, payload, ms = result
        ok = status == expected
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {name}: {status} (expected {expected}) {ms:.0f} ms")
        return payload

    check(
        "unsigned request is refused", 403, request(endpoint, "POST", "/orders", order, sign=False)
    )
    created = check(
        "create order", 201, request(endpoint, "POST", "/orders", order, {"idempotency-key": key})
    )
    replay = check(
        "replay with the same key",
        201,
        request(endpoint, "POST", "/orders", order, {"idempotency-key": key}),
    )
    if isinstance(created, dict) and isinstance(replay, dict):
        same = created.get("order_id") == replay.get("order_id")
        failures += not same
        print(f"{'PASS' if same else 'FAIL'}  replay returns the same order_id")
    other = {**order, "items": [{"sku": "SKU-1", "quantity": 2}]}
    check(
        "same key, different order",
        422,
        request(endpoint, "POST", "/orders", other, {"idempotency-key": key}),
    )
    check("missing key", 400, request(endpoint, "POST", "/orders", order))
    if isinstance(created, dict) and "order_id" in created:
        check("read the order", 200, request(endpoint, "GET", f"/orders/{created['order_id']}"))
    check("unknown order", 404, request(endpoint, "GET", f"/orders/{uuid.uuid4()}"))

    print("All checks passed." if failures == 0 else f"{failures} check(s) failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
