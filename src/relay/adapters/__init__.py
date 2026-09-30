"""Destination adapters.

Adding a destination means writing one Adapter subclass and registering it
here (and in the Terraform `adapter` validation). The relay core never changes.
"""

from __future__ import annotations

from relay.adapters.base import Adapter
from relay.adapters.slack import SlackAdapter
from relay.adapters.webhook import WebhookAdapter

ADAPTERS: dict[str, Adapter] = {
    "slack": SlackAdapter(),
    "webhook": WebhookAdapter(),
}


def get_adapter(name: str) -> Adapter:
    try:
        return ADAPTERS[name]
    except KeyError:
        raise ValueError(f"unknown adapter {name!r}; known: {sorted(ADAPTERS)}") from None


__all__ = ["ADAPTERS", "Adapter", "get_adapter"]
