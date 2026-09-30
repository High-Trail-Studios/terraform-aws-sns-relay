from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

from relay.alert import Alert


class Adapter(ABC):
    """Turns an Alert into the JSON body one destination expects.

    Adapters only shape the payload. The core owns HTTP, auth headers,
    timeouts, and error handling, so every destination gets the same
    retry and DLQ behaviour for free.
    """

    @abstractmethod
    def render(self, alert: Alert) -> dict[str, Any]:
        """Return the JSON-serialisable request body for this alert."""
