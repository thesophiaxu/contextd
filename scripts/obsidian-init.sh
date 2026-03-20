#!/bin/bash
# One-time Obsidian vault initialization for contextd activity graph.
# Creates the vault directory structure and minimal Obsidian config.

set -euo pipefail

VAULT="$HOME/Documents/contextd-vault"

echo "Creating vault at $VAULT ..."
mkdir -p "$VAULT"/{.obsidian,Activities,Apps,Topics,Daily,Maps,Reflections}

# Minimal Obsidian app config
cat > "$VAULT/.obsidian/app.json" << 'JSON'
{
  "defaultViewMode": "preview",
  "showLineNumber": false,
  "strictLineBreaks": false
}
JSON

# Graph view config: color-coded node groups, tuned forces for our structure
cat > "$VAULT/.obsidian/graph.json" << 'JSON'
{
  "collapse-filter": false,
  "search": "",
  "showTags": false,
  "showAttachments": false,
  "hideUnresolved": false,
  "showOrphans": false,
  "collapse-color-groups": false,
  "colorGroups": [
    {"query": "path:Apps", "color": {"a": 1, "r": 74, "g": 158, "b": 255}},
    {"query": "path:Topics", "color": {"a": 1, "r": 179, "g": 102, "b": 255}},
    {"query": "path:Activities", "color": {"a": 1, "r": 100, "g": 200, "b": 150}},
    {"query": "path:Daily", "color": {"a": 1, "r": 255, "g": 170, "b": 100}},
    {"query": "path:Maps", "color": {"a": 1, "r": 240, "g": 200, "b": 50}},
    {"query": "path:Reflections", "color": {"a": 1, "r": 220, "g": 80, "b": 80}}
  ],
  "collapse-display": false,
  "showArrow": false,
  "textFadeMultiplier": 0,
  "nodeSizeMultiplier": 1.2,
  "lineSizeMultiplier": 1,
  "collapse-forces": false,
  "centerStrength": 0.5,
  "repelStrength": 10,
  "linkStrength": 1,
  "linkDistance": 100
}
JSON

echo ""
echo "Obsidian vault initialized at $VAULT"
echo ""
echo "Next steps:"
echo "  1. Open Obsidian"
echo "  2. 'Open folder as vault' -> select $VAULT"
echo "  3. Run: python3 ~/contextd/scripts/obsidian-sync.py"
echo "  4. Open the Graph View (Cmd+G in Obsidian)"
