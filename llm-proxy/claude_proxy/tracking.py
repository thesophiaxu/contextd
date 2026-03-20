"""Usage tracking and improved token estimation.

Persists daily request counts and estimated token totals to
``~/.config/contextd/proxy_usage.json``. Auto-prunes entries older than
30 days on each write.
"""

from __future__ import annotations

import json
import logging
import re
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger("claude-proxy")

USAGE_PATH = Path.home() / ".config" / "contextd" / "proxy_usage.json"
RETENTION_DAYS = 30

# Heuristic patterns that suggest code content
_CODE_INDICATORS = re.compile(
    r"[{};]|^\s*(def |func |class |import |from |const |let |var |#include)",
    re.MULTILINE,
)
_CODE_THRESHOLD = 5  # minimum indicator matches to classify as code


def estimate_tokens(text: str) -> int:
    """Estimate token count using word-based heuristics.

    Uses different multipliers for natural language vs code:
    - English prose: ~1.3 tokens per word
    - Code: ~2.0 tokens per word (more special characters and subword splits)

    Parameters
    ----------
    text : str
        Input text to estimate.

    Returns
    -------
    int
        Estimated token count (minimum 1).
    """
    if not text:
        return 1
    words = text.split()
    word_count = len(words)
    if word_count == 0:
        return 1
    is_code = len(_CODE_INDICATORS.findall(text)) >= _CODE_THRESHOLD
    multiplier = 2.0 if is_code else 1.3
    return max(1, int(word_count * multiplier))


class UsageTracker:
    """Thread-safe daily usage tracker with JSON persistence.

    Parameters
    ----------
    path : Path
        File path for the JSON usage log.
    """

    def __init__(self, path: Path = USAGE_PATH) -> None:
        self._path = path
        self._lock = threading.Lock()
        self._data: dict[str, dict[str, int]] = {}
        self._load()

    def _load(self) -> None:
        """Read existing usage data from disk."""
        try:
            if self._path.exists():
                self._data = json.loads(self._path.read_text("utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            logger.warning("Could not load usage data: %s", exc)
            self._data = {}

    def _save(self) -> None:
        """Write usage data to disk, pruning old entries."""
        cutoff = (
            datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)
        ).strftime("%Y-%m-%d")
        pruned = {k: v for k, v in self._data.items() if k >= cutoff}
        self._data = pruned
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            self._path.write_text(json.dumps(pruned, indent=2) + "\n", "utf-8")
        except OSError as exc:
            logger.warning("Could not save usage data: %s", exc)

    def record(self, estimated_tokens: int) -> None:
        """Record a completed request.

        Parameters
        ----------
        estimated_tokens : int
            Estimated total tokens (prompt + completion) for this request.
        """
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        with self._lock:
            day = self._data.setdefault(today, {"requests": 0, "estimated_tokens": 0})
            day["requests"] += 1
            day["estimated_tokens"] += estimated_tokens
            self._save()

    def today_stats(self) -> dict[str, Any]:
        """Return today's usage statistics.

        Returns
        -------
        dict
            Keys: ``requests``, ``estimated_tokens``.
        """
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        with self._lock:
            return dict(self._data.get(today, {"requests": 0, "estimated_tokens": 0}))
