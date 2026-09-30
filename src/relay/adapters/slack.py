from __future__ import annotations

from typing import Any

from relay.adapters.base import Adapter
from relay.alert import Alert

# Slack truncates long messages anyway; cut earlier so the tail is marked.
MAX_TEXT = 3500

STATE_EMOJI = {
    "ALARM": ":red_circle:",
    "OK": ":large_green_circle:",
    "INSUFFICIENT_DATA": ":white_circle:",
}


def _escape(text: str) -> str:
    # The only three characters Slack mrkdwn requires escaping.
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _truncate(text: str) -> str:
    return text if len(text) <= MAX_TEXT else text[: MAX_TEXT - 15] + "\n…(truncated)"


class SlackAdapter(Adapter):
    """Slack incoming webhook. CloudWatch alarm payloads get a one-line summary."""

    def render(self, alert: Alert) -> dict[str, Any]:
        payload = alert.payload
        if payload and "AlarmName" in payload and "NewStateValue" in payload:
            text = self._cloudwatch_alarm(payload)
        else:
            text = self._generic(alert)
        return {"text": _truncate(text)}

    @staticmethod
    def _cloudwatch_alarm(payload: dict[str, Any]) -> str:
        state = str(payload["NewStateValue"])
        emoji = STATE_EMOJI.get(state, ":grey_question:")
        lines = [f"{emoji} *{_escape(str(payload['AlarmName']))}* is {_escape(state)}"]
        if payload.get("NewStateReason"):
            lines.append(_escape(str(payload["NewStateReason"])))
        if payload.get("Region"):
            lines.append(f"_{_escape(str(payload['Region']))}_")
        return "\n".join(lines)

    @staticmethod
    def _generic(alert: Alert) -> str:
        body = _escape(alert.message)
        if alert.subject:
            return f"*{_escape(alert.subject)}*\n{body}"
        return body
