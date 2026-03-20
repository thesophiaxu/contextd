"""MCP server bridge for contextd's HTTP API.

Exposes contextd screen context search, summaries, activity, and health
as MCP tools over stdio transport. Uses only stdlib HTTP to minimize deps.
"""

from __future__ import annotations

import json
import logging
import sys
import urllib.error
import urllib.request
from typing import Any

from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONTEXTD_BASE_URL = "http://localhost:21890"
HTTP_TIMEOUT_SECONDS = 10

logger = logging.getLogger("contextd_mcp")
logging.basicConfig(stream=sys.stderr, level=logging.INFO)

mcp = FastMCP("contextd", instructions="Screen context from contextd")

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------


def _get(path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    """Make a GET request to contextd.

    Parameters
    ----------
    path : str
        URL path relative to CONTEXTD_BASE_URL (e.g. "/v1/summaries").
    params : dict, optional
        Query parameters to append.

    Returns
    -------
    dict
        Parsed JSON response body.
    """
    url = f"{CONTEXTD_BASE_URL}{path}"
    if params:
        filtered = {k: v for k, v in params.items() if v is not None}
        if filtered:
            qs = urllib.request.urlencode(filtered)  # type: ignore[attr-defined]
            url = f"{url}?{qs}"
    logger.info("GET %s", url)
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.URLError as exc:
        raise ConnectionError(
            f"contextd unreachable at {CONTEXTD_BASE_URL}: {exc}"
        ) from exc


def _post(path: str, body: dict[str, Any]) -> dict[str, Any]:
    """Make a POST request to contextd.

    Parameters
    ----------
    path : str
        URL path relative to CONTEXTD_BASE_URL.
    body : dict
        JSON request body.

    Returns
    -------
    dict
        Parsed JSON response body.
    """
    url = f"{CONTEXTD_BASE_URL}{path}"
    data = json.dumps(body).encode()
    logger.info("POST %s", url)
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.URLError as exc:
        raise ConnectionError(
            f"contextd unreachable at {CONTEXTD_BASE_URL}: {exc}"
        ) from exc


# ---------------------------------------------------------------------------
# MCP tools
# ---------------------------------------------------------------------------


@mcp.tool()
def search_screen_context(
    query: str,
    time_range_minutes: int = 1440,
    limit: int = 20,
) -> str:
    """Search screen captures and OCR text from contextd.

    Parameters
    ----------
    query : str
        Free-text search query.
    time_range_minutes : int, optional
        How far back to search in minutes (default 1440, i.e. 24 hours).
    limit : int, optional
        Maximum number of results (default 20).

    Returns
    -------
    str
        JSON search results or error message.
    """
    try:
        result = _post(
            "/v1/search",
            {
                "query": query,
                "time_range_minutes": time_range_minutes,
                "limit": limit,
            },
        )
        return json.dumps(result, indent=2)
    except ConnectionError as exc:
        return str(exc)


@mcp.tool()
def get_summaries(minutes: int = 60, limit: int = 50) -> str:
    """Get recent activity summaries from contextd.

    Parameters
    ----------
    minutes : int, optional
        Time window in minutes (default 60).
    limit : int, optional
        Maximum number of summaries (default 50).

    Returns
    -------
    str
        JSON summaries or error message.
    """
    try:
        result = _get("/v1/summaries", {"minutes": minutes, "limit": limit})
        return json.dumps(result, indent=2)
    except ConnectionError as exc:
        return str(exc)


@mcp.tool()
def get_activity(
    timestamp: str | None = None,
    window_minutes: int = 5,
    kind: str | None = None,
    limit: int = 100,
) -> str:
    """Get raw activity data from contextd.

    Parameters
    ----------
    timestamp : str, optional
        ISO8601 timestamp to center the query on. Defaults to now.
    window_minutes : int, optional
        Window size in minutes around the timestamp (default 5).
    kind : str, optional
        Filter by kind: "captures" or "summaries".
    limit : int, optional
        Maximum number of results (default 100).

    Returns
    -------
    str
        JSON activity data or error message.
    """
    try:
        result = _get(
            "/v1/activity",
            {
                "timestamp": timestamp,
                "window_minutes": window_minutes,
                "kind": kind,
                "limit": limit,
            },
        )
        return json.dumps(result, indent=2)
    except ConnectionError as exc:
        return str(exc)


@mcp.tool()
def semantic_search(
    query: str,
    time_range_minutes: int = 1440,
    limit: int = 10,
) -> str:
    """Semantic similarity search over screen activity summaries.

    Uses TF-IDF cosine similarity to find summaries that are semantically
    related to the query, even when exact keywords do not match. Complements
    the FTS-based search_screen_context tool.

    Parameters
    ----------
    query : str
        Natural language query describing what you are looking for.
    time_range_minutes : int, optional
        How far back to search in minutes (default 1440, i.e. 24 hours).
    limit : int, optional
        Maximum number of results (default 10).

    Returns
    -------
    str
        JSON results ranked by cosine similarity, or error message.
    """
    try:
        result = _post(
            "/v1/semantic-search",
            {
                "query": query,
                "time_range_minutes": time_range_minutes,
                "limit": limit,
            },
        )
        return json.dumps(result, indent=2)
    except ConnectionError as exc:
        return str(exc)


@mcp.tool()
def get_screen_health() -> str:
    """Check if contextd is running and healthy.

    Returns
    -------
    str
        JSON health status or error message.
    """
    try:
        result = _get("/health")
        return json.dumps(result, indent=2)
    except ConnectionError as exc:
        return str(exc)


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    mcp.run(transport="stdio")
