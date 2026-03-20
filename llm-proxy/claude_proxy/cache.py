"""In-memory LRU cache with TTL for identical prompt deduplication.

Hashes (model, system_prompt, user_content) and returns cached responses
for repeated calls within the TTL window. Prevents redundant ``claude -p``
subprocess spawns when screen content is static.
"""

from __future__ import annotations

import hashlib
import threading
import time
from collections import OrderedDict
from typing import Any

MAX_ENTRIES = 50
TTL_SECONDS = 300  # 5 minutes


class ResponseCache:
    """Thread-safe LRU cache with per-entry TTL.

    Parameters
    ----------
    max_entries : int
        Maximum number of cached responses.
    ttl_seconds : float
        Time-to-live in seconds for each entry.
    """

    def __init__(
        self,
        max_entries: int = MAX_ENTRIES,
        ttl_seconds: float = TTL_SECONDS,
    ) -> None:
        self._max = max_entries
        self._ttl = ttl_seconds
        self._store: OrderedDict[str, tuple[float, dict[str, Any]]] = OrderedDict()
        self._lock = threading.Lock()
        self.hits = 0
        self.misses = 0

    @staticmethod
    def _make_key(model: str, system_prompt: str | None, user_content: str) -> str:
        """Create a deterministic hash key from request parameters.

        Parameters
        ----------
        model : str
            Model alias (e.g. "haiku", "sonnet").
        system_prompt : str or None
            System prompt text.
        user_content : str
            User message content.

        Returns
        -------
        str
            Hex digest of the SHA-256 hash.
        """
        raw = f"{model}\x00{system_prompt or ''}\x00{user_content}"
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()

    def get(
        self, model: str, system_prompt: str | None, user_content: str
    ) -> dict[str, Any] | None:
        """Look up a cached response.

        Parameters
        ----------
        model : str
            Model alias.
        system_prompt : str or None
            System prompt text.
        user_content : str
            User message content.

        Returns
        -------
        dict or None
            Cached response dict, or None on miss/expiry.
        """
        key = self._make_key(model, system_prompt, user_content)
        with self._lock:
            entry = self._store.get(key)
            if entry is None:
                self.misses += 1
                return None
            ts, data = entry
            if time.monotonic() - ts > self._ttl:
                del self._store[key]
                self.misses += 1
                return None
            # Move to end (most recently used)
            self._store.move_to_end(key)
            self.hits += 1
            return data

    def put(
        self,
        model: str,
        system_prompt: str | None,
        user_content: str,
        response: dict[str, Any],
    ) -> None:
        """Store a response in the cache.

        Parameters
        ----------
        model : str
            Model alias.
        system_prompt : str or None
            System prompt text.
        user_content : str
            User message content.
        response : dict
            The response dict to cache.
        """
        key = self._make_key(model, system_prompt, user_content)
        with self._lock:
            if key in self._store:
                self._store.move_to_end(key)
            self._store[key] = (time.monotonic(), response)
            while len(self._store) > self._max:
                self._store.popitem(last=False)

    @property
    def size(self) -> int:
        """Current number of entries (may include expired)."""
        with self._lock:
            return len(self._store)
