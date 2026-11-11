import hashlib
import json
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class Event(BaseModel):
    device_id: str = Field(min_length=1, max_length=64)
    kind: Literal["heart_rate", "steps", "temperature"]
    value: float
    recorded_at: datetime

    def idempotency_key(self) -> str:
        """Deterministic key so the consumer can drop duplicates.

        Uses the fields that define 'the same observation'. Two submissions with
        identical device, kind, and timestamp are the same event even if a retry
        changed nothing else.
        """
        canonical = json.dumps(
            {
                "device_id": self.device_id,
                "kind": self.kind,
                "recorded_at": self.recorded_at.isoformat(),
            },
            sort_keys=True,
        )
        return hashlib.sha256(canonical.encode()).hexdigest()
