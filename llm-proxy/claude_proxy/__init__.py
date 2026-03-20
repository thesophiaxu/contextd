"""OpenAI-compatible HTTP proxy that translates requests to ``claude -p`` calls."""

from claude_proxy.server import main

__all__ = ["main"]
