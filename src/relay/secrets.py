"""SSM SecureString reads with a short in-memory cache.

The cache TTL bounds how long a rotated webhook URL or token takes to be
picked up by warm Lambda containers.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any


class MissingSecret(Exception):
    """A required SSM parameter does not exist."""


class SecretStore:
    def __init__(
        self,
        client: Any = None,
        ttl: float = 300.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._client = client
        self._ttl = ttl
        self._clock = clock
        self._cache: dict[str, tuple[float, str]] = {}

    def get(self, name: str) -> str:
        now = self._clock()
        cached = self._cache.get(name)
        if cached and now - cached[0] < self._ttl:
            return cached[1]

        client = self._ssm()
        try:
            response = client.get_parameter(Name=name, WithDecryption=True)
        except client.exceptions.ParameterNotFound:
            raise MissingSecret(
                f"SSM parameter {name} not found; create it with "
                f"`aws ssm put-parameter --type SecureString --name {name} --value ...`"
            ) from None

        value = response["Parameter"]["Value"]
        self._cache[name] = (now, value)
        return value

    def _ssm(self) -> Any:
        if self._client is None:
            import boto3  # provided by the Lambda runtime

            self._client = boto3.client("ssm")
        return self._client
