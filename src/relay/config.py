"""Non-secret configuration, read once from the Lambda environment."""

from __future__ import annotations

import json
import os
from collections.abc import Mapping
from dataclasses import dataclass

from relay.adapters import get_adapter

HEARTBEAT_SECRET = "_heartbeat/url"


@dataclass(frozen=True)
class Route:
    name: str
    adapter: str
    auth_token: bool = False
    auth_header: str = "Authorization"
    auth_scheme: str = "Bearer"


@dataclass(frozen=True)
class Config:
    routes: dict[str, Route]  # keyed by SNS topic ARN
    ssm_prefix: str
    http_timeout: float = 5.0
    heartbeat: bool = False
    secrets_ttl: float = 300.0

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> Config:
        routes = {
            topic_arn: Route(
                name=r["name"],
                adapter=r["adapter"],
                auth_token=bool(r.get("auth_token", False)),
                auth_header=r.get("auth_header") or "Authorization",
                auth_scheme=r.get("auth_scheme") if r.get("auth_scheme") is not None else "Bearer",
            )
            for topic_arn, r in json.loads(env["RELAY_ROUTES"]).items()
        }
        # Fail at cold start, not on the first alert, if an adapter is unknown.
        for route in routes.values():
            get_adapter(route.adapter)

        return cls(
            routes=routes,
            ssm_prefix=env["RELAY_SSM_PREFIX"].rstrip("/"),
            http_timeout=float(env.get("RELAY_HTTP_TIMEOUT", "5")),
            heartbeat=env.get("RELAY_HEARTBEAT", "false").lower() == "true",
            secrets_ttl=float(env.get("RELAY_SECRETS_TTL_S", "300")),
        )

    def secret_name(self, relative: str) -> str:
        return f"{self.ssm_prefix}/{relative}"
