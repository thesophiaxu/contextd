"""Nightly activity digest from contextd.

Fetches the last 24 hours of screen activity summaries, generates a
concise digest via Claude Haiku, and writes it into the Claude Code
memory directory. Cleans up digest files older than 7 days.
"""

from __future__ import annotations

import glob
import json
import logging
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

CONTEXTD_BASE_URL = "http://localhost:21890"
HTTP_TIMEOUT_SECONDS = 15
MEMORY_DIR = Path.home() / ".claude" / "projects" / "-Users-amit" / "memory"
MEMORY_INDEX = MEMORY_DIR / "MEMORY.md"
DIGEST_RETENTION_DAYS = 7

logger = logging.getLogger("nightly-digest")
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)


def fetch_summaries(minutes: int = 1440, limit: int = 200) -> list[dict]:
    """Fetch activity summaries from contextd.

    Parameters
    ----------
    minutes : int
        Time window in minutes (default 1440 = 24h).
    limit : int
        Max summaries to return.

    Returns
    -------
    list[dict]
        Summary objects from contextd.
    """
    url = f"{CONTEXTD_BASE_URL}/v1/summaries?minutes={minutes}&limit={limit}"
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as resp:
            data = json.loads(resp.read().decode())
    except (urllib.error.URLError, OSError) as exc:
        logger.error("contextd unreachable: %s", exc)
        return []
    if isinstance(data, list):
        return data
    return data.get("summaries", data.get("data", []))


def format_summaries_for_prompt(summaries: list[dict]) -> str:
    """Format raw summaries into a text block for the LLM prompt.

    Parameters
    ----------
    summaries : list[dict]
        Summary objects from contextd.

    Returns
    -------
    str
        Pipe-delimited plain-text, one summary per line.
    """
    lines: list[str] = []
    for s in summaries:
        ts = s.get("timestamp", s.get("created_at", ""))
        app = s.get("app", s.get("application", ""))
        text = s.get("summary", s.get("text", ""))
        if not text:
            continue
        lines.append(" | ".join(p for p in [ts, app, text] if p))
    return "\n".join(lines)


def generate_digest(summaries_text: str) -> str:
    """Generate a 3-5 bullet digest using Claude Haiku.

    Parameters
    ----------
    summaries_text : str
        Formatted summaries to condense.

    Returns
    -------
    str
        Markdown bullet list digest, or empty string on failure.
    """
    prompt = (
        "Below are screen activity summaries from the last 24 hours. "
        "Generate a concise digest of 3-5 bullet points capturing the "
        "main activities, projects worked on, and notable context switches. "
        "Use plain language, no headers, just bullet points starting with -. "
        "Do not use em dashes.\n\n"
        f"{summaries_text}"
    )
    try:
        result = subprocess.run(
            ["claude", "-p", "--model", "haiku", prompt],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
        logger.error("claude command failed: %s", result.stderr)
        return ""
    except FileNotFoundError:
        logger.error("claude CLI not found on PATH")
        return ""
    except subprocess.TimeoutExpired:
        logger.error("claude command timed out")
        return ""


def write_digest(digest_text: str, date_str: str) -> Path:
    """Write the digest to a dated markdown file.

    Parameters
    ----------
    digest_text : str
        Generated digest content.
    date_str : str
        Date in YYYY-MM-DD format.

    Returns
    -------
    Path
        Path to the written file.
    """
    filepath = MEMORY_DIR / f"daily_digest_{date_str}.md"
    content = f"# Daily Activity Digest - {date_str}\n\n{digest_text}\n"
    filepath.write_text(content, encoding="utf-8")
    logger.info("Wrote digest to %s", filepath)
    return filepath


def cleanup_old_digests() -> int:
    """Remove digest files older than DIGEST_RETENTION_DAYS.

    Returns
    -------
    int
        Number of files removed.
    """
    cutoff = datetime.now() - timedelta(days=DIGEST_RETENTION_DAYS)
    pattern = str(MEMORY_DIR / "daily_digest_*.md")
    removed = 0
    for filepath in glob.glob(pattern):
        date_part = os.path.basename(filepath)[14:-3]  # strip prefix/suffix
        try:
            file_date = datetime.strptime(date_part, "%Y-%m-%d")
        except ValueError:
            continue
        if file_date < cutoff:
            os.remove(filepath)
            logger.info("Removed old digest: %s", filepath)
            removed += 1
    return removed


def update_memory_index(date_str: str) -> None:
    """Add or update the digest reference in MEMORY.md.

    Parameters
    ----------
    date_str : str
        Date in YYYY-MM-DD format.
    """
    if not MEMORY_INDEX.exists():
        logger.warning("MEMORY.md not found at %s", MEMORY_INDEX)
        return

    content = MEMORY_INDEX.read_text(encoding="utf-8")
    digest_filename = f"daily_digest_{date_str}.md"
    digest_line = (
        f"- [{digest_filename}]({digest_filename}) "
        f"- Nightly screen activity digest for {date_str}"
    )

    section_header = "## Daily Digests"

    if section_header in content:
        lines = content.split("\n")
        new_lines: list[str] = []
        in_section = False
        replaced = False
        for line in lines:
            if line.strip() == section_header:
                in_section = True
                new_lines.append(line)
                continue
            if in_section:
                if line.startswith("## ") and line.strip() != section_header:
                    if not replaced:
                        new_lines.append(digest_line)
                        replaced = True
                    in_section = False
                    new_lines.append(line)
                elif line.strip().startswith("- [daily_digest_"):
                    if not replaced:
                        new_lines.append(digest_line)
                        replaced = True
                else:
                    new_lines.append(line)
            else:
                new_lines.append(line)
        if in_section and not replaced:
            new_lines.append(digest_line)
        content = "\n".join(new_lines)
    else:
        content = content.rstrip() + f"\n\n{section_header}\n{digest_line}\n"

    MEMORY_INDEX.write_text(content, encoding="utf-8")
    logger.info("Updated MEMORY.md with digest reference")


def main() -> None:
    """Run the nightly digest pipeline."""
    today = datetime.now().strftime("%Y-%m-%d")
    logger.info("Starting nightly digest for %s", today)

    summaries = fetch_summaries(minutes=1440, limit=200)
    if not summaries:
        logger.warning("No summaries available, skipping digest")
        return
    logger.info("Fetched %d summaries", len(summaries))

    summaries_text = format_summaries_for_prompt(summaries)
    if not summaries_text:
        logger.warning("No usable summary text, skipping digest")
        return

    digest = generate_digest(summaries_text)
    if not digest:
        logger.warning("Digest generation failed, skipping write")
        return

    write_digest(digest, today)
    update_memory_index(today)
    removed = cleanup_old_digests()
    logger.info("Cleanup removed %d old digest(s)", removed)
    logger.info("Nightly digest complete")


if __name__ == "__main__":
    main()
