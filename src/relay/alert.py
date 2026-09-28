"""The destination-neutral alert every adapter receives."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class Alert:
    topic_arn: str
    message_id: str
    message: str
    timestamp: str
    subject: str | None = None
    attributes: dict[str, str] = field(default_factory=dict)

    @classmethod
    def from_sns_record(cls, record: dict[str, Any]) -> Alert:
        sns = record["Sns"]
        return cls(
            topic_arn=sns["TopicArn"],
            message_id=sns["MessageId"],
            message=sns.get("Message") or "",
            timestamp=sns.get("Timestamp") or "",
            subject=sns.get("Subject") or None,
            attributes={
                name: attr.get("Value", "")
                for name, attr in (sns.get("MessageAttributes") or {}).items()
            },
        )

    @property
    def payload(self) -> dict[str, Any] | None:
        """The message parsed as a JSON object, or None if it is plain text.

        CloudWatch alarms, EventBridge, and most AWS services publish JSON.
        """
        try:
            parsed = json.loads(self.message)
        except ValueError:
            return None
        return parsed if isinstance(parsed, dict) else None
