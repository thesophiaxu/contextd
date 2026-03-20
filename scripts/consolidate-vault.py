"""Consolidate the contextd Obsidian vault by merging duplicate topics.

Runs every 6 hours via launchd. Sends topics + recent activities to
Claude Sonnet for dedup analysis, merges duplicates, rewrites wikilinks,
and generates a Thinking Map note.
"""
from __future__ import annotations

import json
import logging
import re
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

VAULT_PATH = Path.home() / "Documents" / "contextd-vault"
TOPICS_DIR = VAULT_PATH / "Topics"
ACTIVITIES_DIR = VAULT_PATH / "Activities"
MAPS_DIR = VAULT_PATH / "Maps"
CLAUDE_TIMEOUT = 120

logger = logging.getLogger("consolidate-vault")
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)


def list_topics() -> list[str]:
    """Return all topic names (stem of each .md file in Topics/).

    Returns
    -------
    list[str]
        Sorted list of topic names.
    """
    if not TOPICS_DIR.exists():
        return []
    return sorted(p.stem for p in TOPICS_DIR.glob("*.md"))


def recent_activities(hours: int = 6) -> list[dict[str, str]]:
    """Read activity notes from the last N hours.

    Parameters
    ----------
    hours : int
        How far back to look.

    Returns
    -------
    list[dict[str, str]]
        Each dict has 'name' and 'content' keys.
    """
    if not ACTIVITIES_DIR.exists():
        return []
    cutoff = datetime.now() - timedelta(hours=hours)
    results: list[dict[str, str]] = []
    for path in sorted(ACTIVITIES_DIR.glob("*.md")):
        # Filename format: YYYY-MM-DD_HH-MM.md
        try:
            dt = datetime.strptime(path.stem, "%Y-%m-%d_%H-%M")
        except ValueError:
            continue
        if dt >= cutoff:
            results.append({
                "name": path.stem,
                "content": path.read_text(encoding="utf-8")[:500],
            })
    return results


def build_consolidation_prompt(
    topics: list[str],
    activities: list[dict[str, str]],
) -> str:
    """Build the prompt for Claude Sonnet to analyze duplicates.

    Parameters
    ----------
    topics : list[str]
        Current topic names in the vault.
    activities : list[dict[str, str]]
        Recent activity summaries.

    Returns
    -------
    str
        The full prompt string.
    """
    topic_list = "\n".join(f"- {t}" for t in topics)
    activity_text = "\n\n".join(
        f"### {a['name']}\n{a['content']}" for a in activities
    )
    return (
        "You are consolidating an Obsidian knowledge graph of computer activity.\n\n"
        f"Here are the current topic nodes ({len(topics)} total):\n{topic_list}\n\n"
        f"Recent activities (last 6 hours):\n{activity_text}\n\n"
        "Tasks:\n"
        "1. MERGE duplicates: identify groups of topics that mean the same thing. "
        "Pick the most specific, canonical name and list which topics to merge "
        "into it. Only merge when topics clearly refer to the same concept.\n"
        "2. CONNECTIONS: identify non-obvious connections between different "
        "projects or topics based on the activities.\n"
        "3. THINKING EVOLUTION: how has the user's work evolved over these "
        "6 hours? What patterns emerge?\n\n"
        "Output ONLY valid JSON (no markdown fences, no explanation):\n"
        '{"merges": [{"canonical": "name", "aliases": ["dup1", "dup2"]}], '
        '"connections": [{"from": "topic1", "to": "topic2", '
        '"reason": "explanation"}], '
        '"evolution": "2-3 sentence narrative"}'
    )


def call_claude_sonnet(prompt: str) -> dict | None:
    """Call claude CLI with Sonnet model and parse JSON response.

    Parameters
    ----------
    prompt : str
        The prompt to send.

    Returns
    -------
    dict or None
        Parsed JSON response, or None on failure.
    """
    try:
        result = subprocess.run(
            ["claude", "-p", "--model", "sonnet", prompt],
            capture_output=True,
            text=True,
            timeout=CLAUDE_TIMEOUT,
            check=False,
        )
        if result.returncode != 0 or not result.stdout.strip():
            logger.error("claude failed (rc=%d): %s", result.returncode, result.stderr)
            return None
        text = result.stdout.strip()
        # Strip markdown fences if present
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
        return json.loads(text)
    except FileNotFoundError:
        logger.error("claude CLI not found on PATH")
    except subprocess.TimeoutExpired:
        logger.error("claude timed out after %ds", CLAUDE_TIMEOUT)
    except json.JSONDecodeError as exc:
        logger.error("Failed to parse JSON from claude: %s", exc)
    return None


def execute_merges(merges: list[dict]) -> int:
    """Merge duplicate topic notes and rewrite wikilinks in activities.

    Safety: ensures canonical note exists before deleting any aliases.

    Parameters
    ----------
    merges : list[dict]
        Each dict has 'canonical' (str) and 'aliases' (list[str]).

    Returns
    -------
    int
        Number of alias notes deleted.
    """
    deleted = 0
    for group in merges:
        canonical = group.get("canonical", "")
        aliases = group.get("aliases", [])
        if not canonical or not aliases:
            continue

        # Safety: ensure canonical note exists (or create stub) before deleting
        canonical_path = TOPICS_DIR / f"{canonical}.md"
        if not canonical_path.exists():
            canonical_path.write_text(
                f"---\ntype: topic\n---\n\n# {canonical}\n\n"
                f"Activities mentioning this topic are linked via backlinks.\n",
                encoding="utf-8",
            )

        # Rewrite wikilinks in all activity notes
        for activity_path in ACTIVITIES_DIR.glob("*.md"):
            content = activity_path.read_text(encoding="utf-8")
            original = content
            for alias in aliases:
                # Replace [[Alias]] with [[Canonical]] (case-insensitive)
                pattern = re.compile(
                    r"\[\[" + re.escape(alias) + r"\]\]", re.IGNORECASE
                )
                content = pattern.sub(f"[[{canonical}]]", content)
            if content != original:
                activity_path.write_text(content, encoding="utf-8")

        # Delete alias topic notes
        for alias in aliases:
            if alias == canonical:
                continue
            alias_path = TOPICS_DIR / f"{alias}.md"
            if alias_path.exists():
                alias_path.unlink()
                deleted += 1
                logger.info("Merged: %s -> %s", alias, canonical)

    return deleted


def write_thinking_map(
    evolution: str,
    connections: list[dict],
    now: datetime,
) -> Path:
    """Write a Thinking Map note with evolution narrative and connections.

    Parameters
    ----------
    evolution : str
        Narrative of how work evolved.
    connections : list[dict]
        Connection dicts with 'from', 'to', 'reason' keys.
    now : datetime
        Current timestamp for the filename.

    Returns
    -------
    Path
        Path to the written file.
    """
    MAPS_DIR.mkdir(parents=True, exist_ok=True)
    fname = now.strftime("%Y-%m-%d_%Hh") + ".md"
    fpath = MAPS_DIR / fname

    lines = [
        "---",
        f"date: {now.strftime('%Y-%m-%dT%H:%M:%S')}",
        "type: thinking-map",
        "---",
        "",
        f"# Thinking Map - {now.strftime('%Y-%m-%d %H:%M')}",
        "",
        "## Evolution",
        evolution or "No significant evolution detected this period.",
        "",
    ]

    if connections:
        lines.append("## Connections")
        for conn in connections:
            src = conn.get("from", "?")
            dst = conn.get("to", "?")
            reason = conn.get("reason", "")
            lines.append(f"- [[{src}]] <-> [[{dst}]]: {reason}")
        lines.append("")

    fpath.write_text("\n".join(lines), encoding="utf-8")
    logger.info("Wrote thinking map: %s", fpath)
    return fpath


def main() -> None:
    """Run the vault consolidation pipeline."""
    now = datetime.now()
    logger.info("Starting vault consolidation at %s", now.isoformat())

    topics = list_topics()
    if not topics:
        logger.warning("No topics in vault, nothing to consolidate")
        return

    activities = recent_activities(hours=6)
    logger.info("Found %d topics, %d recent activities", len(topics), len(activities))

    prompt = build_consolidation_prompt(topics, activities)
    response = call_claude_sonnet(prompt)
    if not response:
        logger.error("No valid response from Claude, aborting")
        return

    merges = response.get("merges", [])
    connections = response.get("connections", [])
    evolution = response.get("evolution", "")

    if merges:
        deleted = execute_merges(merges)
        logger.info("Executed %d merge groups, deleted %d alias notes", len(merges), deleted)
    else:
        logger.info("No merges needed")

    write_thinking_map(evolution, connections, now)
    logger.info("Consolidation complete")


if __name__ == "__main__":
    main()
