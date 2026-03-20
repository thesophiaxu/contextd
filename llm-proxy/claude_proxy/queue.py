"""Priority request queue for model-based scheduling.

Sonnet/Opus (enrichment) requests get high priority. Haiku (summarization)
requests get low priority. A single async worker drains high-priority first,
then low-priority, ensuring enrichment is never blocked by bulk summarization.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger("claude-proxy")

PRIORITY_HIGH = "high"
PRIORITY_LOW = "low"

# Models considered low-priority (summarization tier)
_LOW_PRIORITY_ALIASES = frozenset({"haiku"})


@dataclass
class QueuedRequest:
    """A request waiting in the priority queue.

    Parameters
    ----------
    user_text : str
        User message content.
    model_alias : str
        Claude CLI model alias.
    system_prompt : str or None
        Optional system prompt.
    future : asyncio.Future
        Future to resolve with the claude -p result.
    priority : str
        "high" or "low".
    """

    user_text: str
    model_alias: str
    system_prompt: str | None
    future: asyncio.Future[dict[str, Any]]
    priority: str = field(init=False)

    def __post_init__(self) -> None:
        self.priority = (
            PRIORITY_LOW if self.model_alias in _LOW_PRIORITY_ALIASES else PRIORITY_HIGH
        )


class PriorityDispatcher:
    """Two-tier async queue dispatcher.

    High-priority requests (sonnet/opus) are always drained before
    low-priority (haiku). A configurable number of worker tasks process
    requests concurrently.

    Parameters
    ----------
    max_concurrent : int
        Maximum number of concurrent ``claude -p`` subprocesses.
    """

    def __init__(self, max_concurrent: int = 3) -> None:
        self._high: asyncio.Queue[QueuedRequest] = asyncio.Queue()
        self._low: asyncio.Queue[QueuedRequest] = asyncio.Queue()
        self._max_concurrent = max_concurrent
        self._semaphore: asyncio.Semaphore | None = None
        self._workers: list[asyncio.Task[None]] = []
        self._shutdown = False
        self._notify: asyncio.Event | None = None

    def start(self, loop: asyncio.AbstractEventLoop) -> None:
        """Start worker tasks on the given event loop.

        Parameters
        ----------
        loop : asyncio.AbstractEventLoop
            The event loop to schedule workers on.
        """
        self._semaphore = asyncio.Semaphore(self._max_concurrent)
        self._notify = asyncio.Event()
        for i in range(self._max_concurrent):
            task = loop.create_task(self._worker(i))
            self._workers.append(task)

    async def _worker(self, worker_id: int) -> None:
        """Worker loop: drain high-priority first, then low-priority.

        Parameters
        ----------
        worker_id : int
            Numeric identifier for logging.
        """
        from claude_proxy.server import run_claude_subprocess

        while not self._shutdown:
            req = await self._next_request()
            if req is None:
                continue
            assert self._semaphore is not None
            async with self._semaphore:
                logger.debug("Worker %d processing %s request", worker_id, req.priority)
                try:
                    result = await run_claude_subprocess(
                        req.user_text, req.model_alias, req.system_prompt
                    )
                    if not req.future.done():
                        req.future.set_result(result)
                except Exception as exc:
                    if not req.future.done():
                        req.future.set_exception(exc)

    async def _next_request(self) -> QueuedRequest | None:
        """Get the next request, preferring high-priority.

        Returns
        -------
        QueuedRequest or None
            Next request to process, or None if interrupted.
        """
        assert self._notify is not None
        # Check high-priority first (non-blocking)
        try:
            return self._high.get_nowait()
        except asyncio.QueueEmpty:
            pass
        # Then low-priority (non-blocking)
        try:
            return self._low.get_nowait()
        except asyncio.QueueEmpty:
            pass
        # Wait for notification that a new request was enqueued
        self._notify.clear()
        try:
            await asyncio.wait_for(self._notify.wait(), timeout=0.2)
        except asyncio.TimeoutError:
            pass
        # Re-check both queues (high first)
        try:
            return self._high.get_nowait()
        except asyncio.QueueEmpty:
            pass
        try:
            return self._low.get_nowait()
        except asyncio.QueueEmpty:
            return None

    def submit(
        self,
        user_text: str,
        model_alias: str,
        system_prompt: str | None,
        loop: asyncio.AbstractEventLoop,
    ) -> asyncio.Future[dict[str, Any]]:
        """Submit a request to the appropriate priority queue (thread-safe).

        Parameters
        ----------
        user_text : str
            User message content.
        model_alias : str
            Claude CLI model alias.
        system_prompt : str or None
            Optional system prompt.
        loop : asyncio.AbstractEventLoop
            Event loop for creating the future.

        Returns
        -------
        asyncio.Future
            Future that resolves with the ``claude -p`` result dict.
        """
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        req = QueuedRequest(
            user_text=user_text,
            model_alias=model_alias,
            system_prompt=system_prompt,
            future=future,
        )

        def _enqueue() -> None:
            queue = self._high if req.priority == PRIORITY_HIGH else self._low
            queue.put_nowait(req)
            if self._notify is not None:
                self._notify.set()

        loop.call_soon_threadsafe(_enqueue)
        return future

    async def drain(self) -> None:
        """Finish in-flight requests and cancel workers."""
        self._shutdown = True
        for w in self._workers:
            w.cancel()
        await asyncio.gather(*self._workers, return_exceptions=True)
        self._workers.clear()

    @property
    def pending_count(self) -> int:
        """Total requests waiting in both queues."""
        return self._high.qsize() + self._low.qsize()
