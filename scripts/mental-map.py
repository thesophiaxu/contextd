"""6-hour activity mental map: fetch, group, generate via Haiku, write to memory."""
from __future__ import annotations

import glob
import json
import logging
import os
import subprocess
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

CONTEXTD_URL = "http://127.0.0.1:21890"
AUTH_TOKEN_PATH = Path.home() / ".config" / "contextd" / "auth_token"
MEMORY_DIR = Path.home() / ".claude" / "projects" / "-Users-amit" / "memory"
MEMORY_INDEX = MEMORY_DIR / "MEMORY.md"
CLAUDE_TIMEOUT = 60
MAP_RETENTION_DAYS = 3

logger = logging.getLogger("mental-map")
logging.basicConfig(
    stream=sys.stderr, level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

PROMPT_TEMPLATE = (
    "You are analyzing 6 hours of computer activity for a grad student "
    "(MS Data Science, incoming PhD Neuroengineering at Indiana University). "
    "Create a mental map connecting their tasks and workflows.\n\nFormat:\n"
    "## Activity Map - [time range]\n\n### Active Projects\n"
    "- [Project name]: [what was done, which apps, key files/URLs]\n\n"
    "### Task Connections\n- [How different activities relate]\n\n"
    "### Patterns\n- [Work patterns: focus periods, context switching, tools]\n\n"
    "### Open Threads\n- [Things in-progress or unfinished]\n\n"
    "Keep it concise (under 300 words). Focus on connections, not lists. "
    "Do not use em dashes.\n\n"
)


def read_auth_token() -> str:
    """Read contextd bearer token from ~/.config/contextd/auth_token."""
    try:
        return AUTH_TOKEN_PATH.read_text(encoding="utf-8").strip()
    except (OSError, FileNotFoundError) as exc:
        logger.error("Cannot read auth token: %s", exc)
        return ""


def fetch_summaries(token: str) -> list[dict]:
    """Fetch last 6h of summaries from contextd with bearer auth."""
    url = f"{CONTEXTD_URL}/v1/summaries?minutes=360&limit=200"
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except (urllib.error.URLError, OSError) as exc:
        logger.error("contextd unreachable: %s", exc)
        return []
    return data if isinstance(data, list) else data.get("summaries", data.get("data", []))


def group_summaries(summaries: list[dict]) -> str:
    """Group summaries by app into a formatted text block for the LLM."""
    by_app: dict[str, list[str]] = defaultdict(list)
    timestamps: list[str] = []
    for s in summaries:
        ts = s.get("timestamp", s.get("created_at", ""))
        app = s.get("app", s.get("application", "unknown"))
        text = s.get("summary", s.get("text", ""))
        if not text:
            continue
        if ts:
            timestamps.append(ts)
        by_app[app].append(f"  [{ts}] {text}" if ts else f"  {text}")
    if not by_app:
        return ""
    lines: list[str] = []
    if timestamps:
        lines.append(f"Time range: {timestamps[-1]} to {timestamps[0]}\n")
    for app, entries in sorted(by_app.items()):
        lines.append(f"### {app} ({len(entries)} entries)")
        lines.extend(entries)
        lines.append("")
    return "\n".join(lines)


def generate_mental_map(grouped_text: str) -> str:
    """Send grouped activity data to claude -p --model haiku."""
    try:
        result = subprocess.run(
            ["claude", "-p", "--model", "haiku", PROMPT_TEMPLATE + grouped_text],
            capture_output=True, text=True, timeout=CLAUDE_TIMEOUT, check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
        logger.error("claude failed (rc=%d): %s", result.returncode, result.stderr)
    except FileNotFoundError:
        logger.error("claude CLI not found on PATH")
    except subprocess.TimeoutExpired:
        logger.error("claude timed out after %ds", CLAUDE_TIMEOUT)
    return ""


def write_mental_map(content: str, now: datetime) -> Path:
    """Write mental map markdown with frontmatter to memory directory."""
    dh = now.strftime("%Y-%m-%d_%H")
    filepath = MEMORY_DIR / f"mental_map_{dh}.md"
    fm = (f"---\nname: mental_map_{dh}\ndescription: "
          "6-hour activity mental map connecting tasks and workflows\n"
          "type: project\n---\n\n")
    filepath.write_text(fm + content + "\n", encoding="utf-8")
    logger.info("Wrote mental map to %s", filepath)
    return filepath


def cleanup_old_maps() -> int:
    """Remove mental map files older than MAP_RETENTION_DAYS."""
    cutoff = datetime.now() - timedelta(days=MAP_RETENTION_DAYS)
    removed = 0
    for fp in glob.glob(str(MEMORY_DIR / "mental_map_*.md")):
        date_part = os.path.basename(fp)[len("mental_map_"):-len(".md")]
        try:
            file_dt = datetime.strptime(date_part, "%Y-%m-%d_%H")
        except ValueError:
            continue
        if file_dt < cutoff:
            os.remove(fp)
            removed += 1
    return removed


def update_memory_index(date_hour: str) -> None:
    """Add or update the Mental Maps section in MEMORY.md."""
    if not MEMORY_INDEX.exists():
        return
    content = MEMORY_INDEX.read_text(encoding="utf-8")
    fname = f"mental_map_{date_hour}.md"
    entry = f"- [{fname}]({fname}) - 6-hour activity mental map ({date_hour})"
    header = "## Mental Maps"
    if header not in content:
        content = content.rstrip() + f"\n\n{header}\n{entry}\n"
    else:
        out: list[str] = []
        in_sect, replaced = False, False
        for line in content.split("\n"):
            if line.strip() == header:
                in_sect, replaced = True, False
                out.append(line)
            elif in_sect and line.startswith("## "):
                if not replaced:
                    out.append(entry)
                    replaced = True
                in_sect = False
                out.append(line)
            elif in_sect and line.strip().startswith("- [mental_map_"):
                if not replaced:
                    out.append(entry)
                    replaced = True
            else:
                out.append(line)
        if in_sect and not replaced:
            out.append(entry)
        content = "\n".join(out)
    MEMORY_INDEX.write_text(content, encoding="utf-8")
    logger.info("Updated MEMORY.md")


def main() -> None:
    """Run the 6-hour mental map pipeline."""
    now = datetime.now()
    date_hour = now.strftime("%Y-%m-%d_%H")
    logger.info("Starting mental map for %s", date_hour)
    token = read_auth_token()
    if not token:
        logger.error("No auth token, aborting")
        sys.exit(1)
    summaries = fetch_summaries(token)
    if not summaries:
        return logger.warning("No summaries, skipping")
    logger.info("Fetched %d summaries", len(summaries))
    grouped = group_summaries(summaries)
    if not grouped:
        return logger.warning("No usable text, skipping")
    mental_map = generate_mental_map(grouped)
    if not mental_map:
        return logger.warning("Generation failed, skipping")
    write_mental_map(mental_map, now)
    update_memory_index(date_hour)
    removed = cleanup_old_maps()
    logger.info("Done. Cleaned %d old map(s).", removed)


if __name__ == "__main__":
    main()
