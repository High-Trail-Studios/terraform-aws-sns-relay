"""Outbound HTTP. URLs are credentials, so they never appear in errors or logs."""

from __future__ import annotations

import urllib.error
import urllib.request
from urllib.parse import urlsplit


class DeliveryError(Exception):
    """The destination did not accept the request."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # A redirect could carry the auth header to a host we never configured.
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def request(
    method: str,
    url: str,
    *,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 5.0,
) -> int:
    """Send one request and return the status code. Raise DeliveryError unless 2xx."""
    parts = urlsplit(url)
    if parts.scheme != "https":
        raise DeliveryError("destination URL must use https")
    host = parts.hostname or "?"

    req = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    try:
        with _opener.open(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        raise DeliveryError(f"{host} returned HTTP {exc.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        reason = getattr(exc, "reason", exc)
        raise DeliveryError(f"{host} unreachable: {type(reason).__name__}") from None
