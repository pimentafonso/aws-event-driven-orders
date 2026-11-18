"""Set the stock of the demo products (SKU-1 to SKU-5).

Usage:
    python scripts/seed_stock.py [available] [table]

Defaults: 100 units each, table aedo-dev-orders. Overwrites current stock.
Uses the default AWS credential chain.
"""

from __future__ import annotations

import sys

import boto3

SKUS = [f"SKU-{n}" for n in range(1, 6)]


def main() -> int:
    available = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    table_name = sys.argv[2] if len(sys.argv) > 2 else "aedo-dev-orders"
    table = boto3.resource("dynamodb", region_name="eu-west-1").Table(table_name)
    with table.batch_writer() as batch:
        for sku in SKUS:
            batch.put_item(Item={"pk": f"PRODUCT#{sku}", "sk": "STOCK", "available": available})
    print(f"{len(SKUS)} products set to {available} units in {table_name}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
