"""HTTP server: caching, priority queuing, usage tracking, graceful shutdown."""
from __future__ import annotations

import asyncio
import json
import logging
import shutil
import signal
import sys
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

from claude_proxy.cache import ResponseCache
from claude_proxy.queue import PriorityDispatcher
from claude_proxy.tracking import UsageTracker, estimate_tokens

logger = logging.getLogger("claude-proxy")
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr,
)

HOST = "127.0.0.1"
DEFAULT_PORT = 11434
SUBPROCESS_TIMEOUT = 120
MAX_CONCURRENT = 3

MODEL_MAP: dict[str, str] = {
    "anthropic/claude-haiku-4-5": "haiku",
    "anthropic/claude-sonnet-4-6": "sonnet",
    "anthropic/claude-opus-4-5": "opus",
}

# Singletons initialized in main()
_loop: asyncio.AbstractEventLoop | None = None
_cache: ResponseCache | None = None
_tracker: UsageTracker | None = None
_dispatcher: PriorityDispatcher | None = None
_start_time: float = 0.0


async def run_claude_subprocess(
    user_text: str,
    model_alias: str,
    system_prompt: str | None = None,
) -> dict[str, Any]:
    """Run ``claude -p`` as an async subprocess, return parsed JSON or error dict."""
    claude_path = shutil.which("claude")
    if not claude_path:
        return {"is_error": True, "result": "claude CLI not found on PATH"}
    cmd = [claude_path, "-p", "--model", model_alias, "--output-format", "json", "--max-turns", "1"]
    if system_prompt:
        cmd.extend(["--system-prompt", system_prompt])
    logger.info("Running claude -p --model %s", model_alias)
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout_bytes, stderr_bytes = await asyncio.wait_for(
            proc.communicate(input=user_text.encode("utf-8")),
            timeout=SUBPROCESS_TIMEOUT,
        )
    except asyncio.TimeoutError:
        logger.error("claude -p timed out after %ds", SUBPROCESS_TIMEOUT)
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        return {"is_error": True, "result": f"Timed out after {SUBPROCESS_TIMEOUT}s"}
    except (FileNotFoundError, OSError) as exc:
        return {"is_error": True, "result": f"Failed to spawn claude: {exc}"}

    stdout = stdout_bytes.decode("utf-8", errors="replace").strip()
    stderr = stderr_bytes.decode("utf-8", errors="replace").strip()
    if stderr:
        logger.debug("claude stderr: %s", stderr[:500])
    if proc.returncode != 0:
        logger.error("claude -p exited %d: %s", proc.returncode, stderr[:500])
        if stdout:
            try:
                data = json.loads(stdout)
                if data.get("result") and not data.get("is_error"):
                    return data
            except json.JSONDecodeError:
                pass
        return {"is_error": True, "result": stderr or stdout[:500] or "claude -p failed"}
    if not stdout:
        return {"is_error": True, "result": "claude -p returned empty output"}
    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        return {"result": stdout, "is_error": False}


def _build_response(model: str, content: str, prompt_text: str) -> dict[str, Any]:
    """Build an OpenAI chat.completions response dict with token estimates."""
    pt = estimate_tokens(prompt_text)
    ct = estimate_tokens(content)
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": content},
            "finish_reason": "stop",
        }],
        "usage": {"prompt_tokens": pt, "completion_tokens": ct, "total_tokens": pt + ct},
    }


def _build_error(model: str, msg: str, code: int = 500) -> dict[str, Any]:
    """Build an OpenAI error response dict."""
    return {
        "error": {"message": msg, "type": "server_error", "param": None, "code": str(code)},
    }


def _parse_messages(
    messages: list[dict[str, str]],
) -> tuple[str | None, str]:
    """Extract system prompt and user text from OpenAI-format messages."""
    system_parts: list[str] = []
    user_parts: list[str] = []
    for msg in messages:
        role, content = msg.get("role", "user"), msg.get("content", "")
        if role == "system":
            system_parts.append(content)
        elif role == "assistant":
            user_parts.append(f"[Previous assistant response]\n{content}")
        else:
            user_parts.append(content)
    system_prompt = "\n\n".join(system_parts) if system_parts else None
    return system_prompt, "\n\n".join(user_parts)


def _wait_for_async(future: asyncio.Future[dict[str, Any]]) -> dict[str, Any]:
    """Block the current thread until an asyncio Future completes."""
    assert _loop is not None
    done_event = threading.Event()
    _loop.call_soon_threadsafe(future.add_done_callback, lambda _f: done_event.set())
    if not done_event.wait(timeout=SUBPROCESS_TIMEOUT + 10):
        raise TimeoutError
    return future.result()


class ProxyHandler(BaseHTTPRequestHandler):
    """HTTP handler translating OpenAI requests to claude -p calls."""

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        logger.info(format, *args)

    def do_GET(self) -> None:  # noqa: N802
        """Handle GET /health and GET /stats."""
        if self.path == "/health":
            self._json({"status": "ok"}, HTTPStatus.OK)
        elif self.path == "/stats":
            assert _cache is not None and _tracker is not None
            self._json({
                "today": _tracker.today_stats(),
                "cache_hits": _cache.hits,
                "cache_size": _cache.size,
                "uptime_seconds": round(time.monotonic() - _start_time, 1),
            }, HTTPStatus.OK)
        else:
            self._json({"error": "Not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        """Handle POST /v1/chat/completions."""
        if self.path != "/v1/chat/completions":
            self._json({"error": f"Unknown endpoint: {self.path}"}, HTTPStatus.NOT_FOUND)
            return
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self._json(_build_error("unknown", "Empty request body", 400), HTTPStatus.BAD_REQUEST)
            return
        try:
            body = json.loads(self.rfile.read(length))
        except json.JSONDecodeError as exc:
            self._json(_build_error("unknown", f"Invalid JSON: {exc}", 400), HTTPStatus.BAD_REQUEST)
            return

        model_name = body.get("model", "anthropic/claude-sonnet-4-6")
        messages: list[dict[str, str]] = body.get("messages", [])
        if not messages:
            self._json(_build_error(model_name, "Empty messages array", 400), HTTPStatus.BAD_REQUEST)
            return
        model_alias = MODEL_MAP.get(model_name, "sonnet")
        system_prompt, user_text = _parse_messages(messages)
        if not user_text.strip():
            self._json(
                _build_error(model_name, "No user content in messages", 400), HTTPStatus.BAD_REQUEST,
            )
            return

        # Check cache
        assert _cache is not None
        cached = _cache.get(model_alias, system_prompt, user_text)
        if cached is not None:
            logger.info("Cache hit for %s request", model_alias)
            self._json(cached, HTTPStatus.OK)
            return

        # Submit via priority dispatcher
        assert _loop is not None and _dispatcher is not None
        async_future = _dispatcher.submit(user_text, model_alias, system_prompt, _loop)
        try:
            result = _wait_for_async(async_future)
        except TimeoutError:
            self._json(_build_error(model_name, "Request timed out", 504), HTTPStatus.GATEWAY_TIMEOUT)
            return
        except Exception as exc:
            logger.exception("Unexpected error in claude -p")
            self._json(_build_error(model_name, str(exc), 500), HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        if result.get("is_error"):
            err = result.get("result", "Unknown claude -p error")
            logger.error("claude -p error: %s", err)
            self._json(_build_error(model_name, err, 502), HTTPStatus.BAD_GATEWAY)
            return

        text = result.get("result", "")
        response = _build_response(model_name, text, (system_prompt or "") + "\n" + user_text)
        _cache.put(model_alias, system_prompt, user_text, response)
        assert _tracker is not None
        _tracker.record(response["usage"]["total_tokens"])
        self._json(response, HTTPStatus.OK)

    def _json(self, data: dict[str, Any], status: HTTPStatus) -> None:
        """Write a JSON HTTP response."""
        payload = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(payload)


def main(port: int = DEFAULT_PORT) -> None:
    """Start the proxy server on ``HOST:port``."""
    global _loop, _cache, _tracker, _dispatcher, _start_time  # noqa: PLW0603
    claude_path = shutil.which("claude")
    if claude_path:
        logger.info("Found claude CLI at: %s", claude_path)
    else:
        logger.warning("claude CLI not on PATH; requests will fail until installed")
    _start_time = time.monotonic()
    _cache = ResponseCache()
    _tracker = UsageTracker()
    _loop = asyncio.new_event_loop()
    _dispatcher = PriorityDispatcher(max_concurrent=MAX_CONCURRENT)

    def _run_loop() -> None:
        asyncio.set_event_loop(_loop)
        _dispatcher.start(_loop)
        _loop.run_forever()

    event_thread = threading.Thread(target=_run_loop, daemon=True)
    event_thread.start()
    server = HTTPServer((HOST, port), ProxyHandler)
    logger.info("Claude proxy listening on http://%s:%d", HOST, port)
    logger.info("  POST /v1/chat/completions  |  GET /health  |  GET /stats")

    shutdown_event = threading.Event()

    def _graceful_shutdown(signum: int, _frame: Any) -> None:
        logger.info("Received %s, shutting down...", signal.Signals(signum).name)
        shutdown_event.set()
    signal.signal(signal.SIGTERM, _graceful_shutdown)
    signal.signal(signal.SIGINT, _graceful_shutdown)

    server.timeout = 0.5
    try:
        while not shutdown_event.is_set():
            server.handle_request()
    finally:
        logger.info("Draining in-flight requests...")
        if _dispatcher and _loop:
            fut = asyncio.run_coroutine_threadsafe(_dispatcher.drain(), _loop)
            try:
                fut.result(timeout=10)
            except Exception:
                logger.warning("Drain timed out, forcing shutdown")
        server.server_close()
        if _loop:
            _loop.call_soon_threadsafe(_loop.stop)
        event_thread.join(timeout=5)
        logger.info("Shutdown complete.")
