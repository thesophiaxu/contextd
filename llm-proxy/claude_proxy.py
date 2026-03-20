"""Backward-compatible entry point.

Delegates to the ``claude_proxy`` package. Existing invocations of
``python claude_proxy.py`` and ``python claude_proxy.py --port 8080``
continue to work unchanged.
"""

from __future__ import annotations

from claude_proxy.server import DEFAULT_PORT, main

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Claude -p LLM proxy server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Listen port")
    main(port=parser.parse_args().port)
