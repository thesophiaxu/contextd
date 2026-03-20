"""Sync contextd summaries to an Obsidian vault with wikilinks.

Reads summaries from the contextd API, writes Activity/App/Topic/Daily
notes with [[wikilinks]] so Obsidian's graph view visualizes connections.
"""
from __future__ import annotations

import json
import logging
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

CONTEXTD_URL = "http://127.0.0.1:21890"
AUTH_TOKEN_PATH = Path.home() / ".config" / "contextd" / "auth_token"
VAULT_PATH = Path.home() / "Documents" / "contextd-vault"
HTTP_TIMEOUT = 15
DEFAULT_HOURS = 2

logger = logging.getLogger("obsidian-sync")
logging.basicConfig(
    stream=sys.stderr, level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)


def read_auth_token() -> str:
    """Read contextd bearer token from ~/.config/contextd/auth_token."""
    try:
        return AUTH_TOKEN_PATH.read_text(encoding="utf-8").strip()
    except (OSError, FileNotFoundError) as exc:
        logger.error("Cannot read auth token: %s", exc)
        return ""


def fetch_summaries(token: str, hours: int = DEFAULT_HOURS) -> list[dict]:
    """Fetch recent summaries from the contextd API."""
    url = f"{CONTEXTD_URL}/v1/summaries?minutes={hours * 60}&limit=200"
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            data = json.loads(resp.read().decode())
    except (urllib.error.URLError, OSError) as exc:
        logger.error("contextd unreachable: %s", exc)
        return []
    if isinstance(data, list):
        return data
    return data.get("summaries", data.get("data", []))


def sanitize(name: str) -> str:
    """Strip special chars, collapse whitespace, title-case, cap at 60."""
    cleaned = re.sub(r"\s+", " ", re.sub(r"[^\w\s\-.]", "", name)).strip()
    return cleaned[:60].title() if cleaned else "Unknown"


def parse_ts(ts: str) -> datetime | None:
    """Parse ISO 8601 timestamp to local naive datetime, or None."""
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            dt = datetime.strptime(ts, fmt)
            if dt.tzinfo is not None:
                dt = dt.astimezone().replace(tzinfo=None)
            return dt
        except ValueError:
            continue
    return None


def round_to_window(dt: datetime, window_min: int = 15) -> datetime:
    """Round datetime down to the nearest N-minute boundary."""
    return dt.replace(minute=(dt.minute // window_min) * window_min, second=0, microsecond=0)


def _dedup(items: list[str]) -> list[str]:
    """Deduplicate preserving insertion order."""
    seen: set[str] = set()
    return [x for x in items if x not in seen and not seen.add(x)]


def write_activity_note(window_start: datetime, summaries: list[dict]) -> bool:
    """Write an Activity note for a 15-min window. Skip if file exists."""
    fname = window_start.strftime("%Y-%m-%d_%H-%M")
    fpath = VAULT_PATH / "Activities" / f"{fname}.md"
    if fpath.exists():
        return False

    start_str = window_start.strftime("%H:%M")
    end_str = (window_start + timedelta(minutes=15)).strftime("%H:%M")

    all_apps: list[str] = []
    all_topics: list[str] = []
    text_parts: list[str] = []
    for s in summaries:
        apps = [sanitize(a) for a in s.get("app_names", [])]
        topics = [sanitize(t) for t in s.get("key_topics", [])]
        all_apps.extend(apps)
        all_topics.extend(topics)
        text = s.get("summary", "").strip()
        if text:
            for name in apps + topics:
                text = re.compile(re.escape(name), re.IGNORECASE).sub(
                    f"[[{name}]]", text, count=1)
            text_parts.append(text)

    apps = _dedup(all_apps)
    topics = _dedup(all_topics)
    lines = [
        "---",
        f"date: {window_start.strftime('%Y-%m-%dT%H:%M:%S')}",
        f"apps: [{', '.join(apps)}]",
        f"topics: [{', '.join(topics)}]",
        "---", "", f"# {start_str} - {end_str}", "",
    ]
    if text_parts:
        lines.extend(text_parts + [""])
    if apps:
        lines.extend(["## Apps"] + [f"- [[{a}]]" for a in apps] + [""])
    if topics:
        lines.extend(["## Topics"] + [f"- [[{t}]]" for t in topics] + [""])

    fpath.write_text("\n".join(lines), encoding="utf-8")
    return True


def ensure_stub(folder: str, name: str, note_type: str) -> None:
    """Create a stub App or Topic note if it does not exist."""
    fpath = VAULT_PATH / folder / f"{name}.md"
    if not fpath.exists():
        fpath.write_text(
            f"---\ntype: {note_type}\n---\n\n# {name}\n\n"
            f"Activities mentioning this {note_type} are linked via backlinks.\n",
            encoding="utf-8",
        )


def update_daily_note(date: datetime, filenames: list[str]) -> None:
    """Create or overwrite the Daily overview note for a given date."""
    ds = date.strftime("%Y-%m-%d")
    lines = [
        "---", f"date: {ds}", "---", "",
        f"# {date.strftime('%B %d, %Y')}", "", "## Activities",
    ] + [f"- [[{n}]]" for n in sorted(set(filenames))] + [""]
    (VAULT_PATH / "Daily" / f"{ds}.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    """Run the Obsidian sync pipeline."""
    hours = DEFAULT_HOURS
    if len(sys.argv) > 1:
        try:
            hours = int(sys.argv[1])
        except ValueError:
            pass

    logger.info("Syncing last %d hours to %s", hours, VAULT_PATH)
    for sub in ("Activities", "Apps", "Topics", "Daily", ".obsidian"):
        (VAULT_PATH / sub).mkdir(parents=True, exist_ok=True)

    token = read_auth_token()
    if not token:
        logger.error("No auth token found, aborting")
        sys.exit(1)

    summaries = fetch_summaries(token, hours=hours)
    if not summaries:
        logger.warning("No summaries returned, nothing to sync")
        return
    logger.info("Fetched %d summaries", len(summaries))

    # Group summaries into 15-min windows
    windows: dict[datetime, list[dict]] = {}
    for s in summaries:
        dt = parse_ts(s.get("start_timestamp", s.get("timestamp", "")))
        if dt:
            windows.setdefault(round_to_window(dt), []).append(s)

    written = 0
    all_apps: set[str] = set()
    all_topics: set[str] = set()
    daily: dict[str, list[str]] = {}

    for ws, ws_summaries in sorted(windows.items()):
        if write_activity_note(ws, ws_summaries):
            written += 1
        daily.setdefault(ws.strftime("%Y-%m-%d"), []).append(ws.strftime("%Y-%m-%d_%H-%M"))
        for s in ws_summaries:
            all_apps.update(sanitize(a) for a in s.get("app_names", []))
            all_topics.update(sanitize(t) for t in s.get("key_topics", []))

    for app in sorted(all_apps):
        ensure_stub("Apps", app, "app")
    for topic in sorted(all_topics):
        ensure_stub("Topics", topic, "topic")
    for ds, fnames in daily.items():
        update_daily_note(datetime.strptime(ds, "%Y-%m-%d"), fnames)

    logger.info(
        "Done: %d new activities, %d apps, %d topics, %d daily notes",
        written, len(all_apps), len(all_topics), len(daily),
    )


if __name__ == "__main__":
    main()
