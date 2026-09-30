"""Lambda entry point: SNS record in, one HTTP request out.

Raising from the handler is deliberate: Lambda retries the event, then sends
it to the DLQ. Heartbeat failures never raise, because a retry would resend
an alert that was already delivered.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from relay import transport
from relay.adapters import get_adapter
from relay.alert import Alert
from relay.config import HEARTBEAT_SECRET, Config, Route
from relay.secrets import SecretStore

log = logging.getLogger("relay")
log.setLevel(logging.INFO)

_config: Config | None = None
_secrets: SecretStore | None = None


class UnknownTopic(Exception):
    """A record arrived from a topic with no configured route."""


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    config, secrets = _deps()

    if event.get("relay_heartbeat"):
        return scheduled_heartbeat(config, secrets)

    records = event.get("Records") or []
    for record in records:
        relay_record(record, config, secrets)

    if records and config.heartbeat:
        ping_heartbeat(config, secrets)
    return {"relayed": len(records)}


def relay_record(record: dict[str, Any], config: Config, secrets: SecretStore) -> None:
    alert = Alert.from_sns_record(record)
    route = config.routes.get(alert.topic_arn)
    if route is None:
        raise UnknownTopic(f"no route for topic {alert.topic_arn}")

    body = json.dumps(get_adapter(route.adapter).render(alert)).encode()
    headers = {"Content-Type": "application/json", **auth_headers(route, config, secrets)}
    status = transport.request(
        "POST",
        secrets.get(config.secret_name(f"{route.name}/url")),
        body=body,
        headers=headers,
        timeout=config.http_timeout,
    )
    log.info("relayed message_id=%s route=%s status=%s", alert.message_id, route.name, status)


def auth_headers(route: Route, config: Config, secrets: SecretStore) -> dict[str, str]:
    if not route.auth_token:
        return {}
    token = secrets.get(config.secret_name(f"{route.name}/token"))
    return {route.auth_header: f"{route.auth_scheme} {token}" if route.auth_scheme else token}


def ping_heartbeat(config: Config, secrets: SecretStore) -> bool:
    """Best effort. Returns False instead of raising."""
    try:
        transport.request(
            "GET",
            secrets.get(config.secret_name(HEARTBEAT_SECRET)),
            timeout=config.http_timeout,
        )
    except Exception as exc:  # noqa: BLE001 - must never fail the invocation
        log.warning("heartbeat ping failed: %s", exc)
        return False
    return True


def scheduled_heartbeat(config: Config, secrets: SecretStore) -> dict[str, Any]:
    """Ping only if every route's secrets resolve, so a broken config goes quiet
    and the heartbeat monitor alerts. Destinations are never contacted."""
    if not config.heartbeat:
        return {"heartbeat": "disabled"}

    for route in config.routes.values():
        try:
            secrets.get(config.secret_name(f"{route.name}/url"))
            auth_headers(route, config, secrets)
        except Exception as exc:  # noqa: BLE001
            log.error("heartbeat withheld: route=%s not ready: %s", route.name, exc)
            return {"heartbeat": "withheld"}

    return {"heartbeat": "sent" if ping_heartbeat(config, secrets) else "failed"}


def _deps() -> tuple[Config, SecretStore]:
    global _config, _secrets
    if _config is None or _secrets is None:
        _config = Config.from_env()
        _secrets = SecretStore(ttl=_config.secrets_ttl)
    return _config, _secrets
