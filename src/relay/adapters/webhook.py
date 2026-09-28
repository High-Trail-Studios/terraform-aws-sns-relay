from __future__ import annotations

from typing import Any

from relay.adapters.base import Adapter
from relay.alert import Alert


class WebhookAdapter(Adapter):
    """Generic JSON POST. `id` is the SNS MessageId: stable across SNS
    redeliveries and relay retries, so receivers can use it to deduplicate."""

    def render(self, alert: Alert) -> dict[str, Any]:
        return {
            "source": "sns-relay",
            "id": alert.message_id,
            "topic_arn": alert.topic_arn,
            "timestamp": alert.timestamp,
            "subject": alert.subject,
            "message": alert.message,
            "attributes": alert.attributes,
        }
