"""Fault injection for resilience experiments, switched on in Parameter Store.

The parameter named by FAULTS_PARAMETER holds failure rates between 0 and 1:

    {"payment_unavailable_rate": 0.5, "notifier_failure_rate": 0}

Values are cached for MAX_AGE_SECONDS, so a change takes effect within that
time and without a deploy. With no parameter configured (unit tests, local
runs), or if it cannot be read, every rate is 0: the switch itself must never
break the order flow.
"""

from __future__ import annotations

import os
import random
from typing import Any

from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.parameters import get_parameter

logger = Logger(child=True)

MAX_AGE_SECONDS = 10
PAYMENT_UNAVAILABLE = "payment_unavailable_rate"
NOTIFIER_FAILURE = "notifier_failure_rate"


def _load() -> dict[str, Any]:
    name = os.environ.get("FAULTS_PARAMETER")
    if not name:
        return {}
    try:
        values = get_parameter(name, transform="json", max_age=MAX_AGE_SECONDS)
    except Exception:  # any failure to read the switch means "no faults"
        logger.warning("fault switch unreadable; injecting nothing", exc_info=True)
        return {}
    return values if isinstance(values, dict) else {}


def rate(name: str) -> float:
    try:
        value = float(_load().get(name, 0))
    except (TypeError, ValueError):
        return 0.0
    return min(max(value, 0.0), 1.0)


def should_fail(name: str) -> bool:
    """True if this call should fail, with the probability set for `name`."""
    chance = rate(name)
    # Not cryptographic: a coin toss for fault injection.
    if chance > 0 and random.random() < chance:  # noqa: S311
        logger.warning("injecting fault", extra={"fault": name, "rate": chance})
        return True
    return False
