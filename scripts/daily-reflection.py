"""Daily reflection on computer activity using Claude Opus.

Runs once per day at 23:00 via launchd. Reads all activity notes and
thinking maps from today, sends them to Claude Opus for an insightful
reflection, and writes the result to the Obsidian vault.
"""
from __future__ import annotations

import logging
import subprocess
import sys
from datetime import datetime
from pathlib import Path

VAULT_PATH = Path.home() / "Documents" / "contextd-vault"
ACTIVITIES_DIR = VAULT_PATH / "Activities"
MAPS_DIR = VAULT_PATH / "Maps"
REFLECTIONS_DIR = VAULT_PATH / "Reflections"
CLAUDE_TIMEOUT = 180

logger = logging.getLogger("daily-reflection")
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)


def read_todays_activities(date_str: str) -> list[str]:
    """Read all activity notes from today.

    Parameters
    ----------
    date_str : str
        Date in YYYY-MM-DD format.

    Returns
    -------
    list[str]
        List of activity note contents (truncated to 400 chars each).
    """
    if not ACTIVITIES_DIR.exists():
        return []
    results: list[str] = []
    for path in sorted(ACTIVITIES_DIR.glob(f"{date_str}_*.md")):
        content = path.read_text(encoding="utf-8")
        # Skip frontmatter, keep body
        body = content.split("---", 2)[-1].strip() if "---" in content else content
        if body:
            results.append(f"[{path.stem}]\n{body[:400]}")
    return results


def read_todays_maps(date_str: str) -> list[str]:
    """Read thinking map notes from today.

    Parameters
    ----------
    date_str : str
        Date in YYYY-MM-DD format.

    Returns
    -------
    list[str]
        List of map note contents.
    """
    if not MAPS_DIR.exists():
        return []
    results: list[str] = []
    for path in sorted(MAPS_DIR.glob(f"{date_str}_*.md")):
        content = path.read_text(encoding="utf-8")
        body = content.split("---", 2)[-1].strip() if "---" in content else content
        if body:
            results.append(body[:600])
    return results


def build_reflection_prompt(
    activities: list[str],
    maps: list[str],
    date_str: str,
) -> str:
    """Build the Opus prompt for daily reflection.

    Parameters
    ----------
    activities : list[str]
        Today's activity note contents.
    maps : list[str]
        Today's thinking map contents.
    date_str : str
        Date in YYYY-MM-DD format.

    Returns
    -------
    str
        The full prompt string.
    """
    activities_text = "\n\n".join(activities) if activities else "(no activities)"
    maps_text = "\n\n---\n\n".join(maps) if maps else "(no maps)"

    return (
        "You are writing a daily reflection on a grad student's computer activity.\n"
        "The student is doing MS Data Science / incoming PhD Neuroengineering "
        "at Indiana University.\n"
        "Research: Diffuse Optical Tomography, neonatal brain imaging.\n\n"
        f"Date: {date_str}\n\n"
        f"Today's activities ({len(activities)} entries):\n{activities_text}\n\n"
        f"Today's thinking evolution maps:\n{maps_text}\n\n"
        "Write a reflection that:\n"
        "1. Identifies the 2-3 main threads of work today\n"
        "2. Notes how thinking evolved (what started as X became Y)\n"
        "3. Spots patterns (e.g., 'spent 3 hours debugging before switching to "
        "research' or 'deep focus block in the morning')\n"
        "4. Suggests connections between projects that may not be obvious\n"
        "5. Notes any unfinished threads to pick up tomorrow\n\n"
        "Keep it under 200 words. Be insightful, not descriptive. "
        "Do not use em dashes. Do not use markdown headers. "
        "Write in second person ('you') as if talking to the student."
    )


def call_claude_opus(prompt: str) -> str:
    """Call claude CLI with Opus model and return the text response.

    Parameters
    ----------
    prompt : str
        The prompt to send.

    Returns
    -------
    str
        Response text, or empty string on failure.
    """
    try:
        result = subprocess.run(
            ["claude", "-p", "--model", "opus", prompt],
            capture_output=True,
            text=True,
            timeout=CLAUDE_TIMEOUT,
            check=False,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
        logger.error("claude failed (rc=%d): %s", result.returncode, result.stderr)
    except FileNotFoundError:
        logger.error("claude CLI not found on PATH")
    except subprocess.TimeoutExpired:
        logger.error("claude timed out after %ds", CLAUDE_TIMEOUT)
    return ""


def write_reflection(reflection: str, date_str: str) -> Path:
    """Write the daily reflection note to the vault.

    Parameters
    ----------
    reflection : str
        The reflection text from Opus.
    date_str : str
        Date in YYYY-MM-DD format.

    Returns
    -------
    Path
        Path to the written file.
    """
    REFLECTIONS_DIR.mkdir(parents=True, exist_ok=True)
    fpath = REFLECTIONS_DIR / f"{date_str}.md"

    lines = [
        "---",
        f"date: {date_str}",
        "type: daily-reflection",
        "---",
        "",
        f"# Reflection - {date_str}",
        "",
        reflection,
        "",
    ]

    fpath.write_text("\n".join(lines), encoding="utf-8")
    logger.info("Wrote reflection: %s", fpath)
    return fpath


def main() -> None:
    """Run the daily reflection pipeline."""
    date_str = datetime.now().strftime("%Y-%m-%d")
    logger.info("Starting daily reflection for %s", date_str)

    activities = read_todays_activities(date_str)
    maps = read_todays_maps(date_str)

    if not activities and not maps:
        logger.warning("No activities or maps for today, skipping reflection")
        return

    logger.info("Found %d activities, %d thinking maps", len(activities), len(maps))

    prompt = build_reflection_prompt(activities, maps, date_str)
    reflection = call_claude_opus(prompt)
    if not reflection:
        logger.error("Reflection generation failed, aborting")
        return

    write_reflection(reflection, date_str)
    logger.info("Daily reflection complete")


if __name__ == "__main__":
    main()
