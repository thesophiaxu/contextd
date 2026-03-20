#!/bin/bash
# Install all launchd agents for contextd.
# Copies plists to ~/Library/LaunchAgents and loads them so contextd
# services auto-start on login.
#
# Usage:
#   ./scripts/install-launchd.sh          # install all agents
#   ./scripts/install-launchd.sh --remove # unload and remove all agents

set -euo pipefail

LAUNCHD_DIR="$HOME/Library/LaunchAgents"
SRC_DIR="$(cd "$(dirname "$0")/../launchd" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Ensure target directory exists
mkdir -p "$LAUNCHD_DIR"

if [ "${1:-}" = "--remove" ]; then
    echo -e "${CYAN}Removing contextd launchd agents...${RESET}"
    for plist in "$SRC_DIR"/com.contextd.*.plist; do
        [ -f "$plist" ] || continue
        name=$(basename "$plist")
        if [ -f "$LAUNCHD_DIR/$name" ]; then
            launchctl unload "$LAUNCHD_DIR/$name" 2>/dev/null || true
            rm -f "$LAUNCHD_DIR/$name"
            echo -e "  ${YELLOW}Removed: $name${RESET}"
        else
            echo -e "  (not installed: $name)"
        fi
    done
    echo -e "${GREEN}All contextd launchd agents removed.${RESET}"
    exit 0
fi

echo -e "${CYAN}Installing contextd launchd agents...${RESET}"
echo -e "  Source:  $SRC_DIR"
echo -e "  Target:  $LAUNCHD_DIR"
echo ""

installed=0
for plist in "$SRC_DIR"/com.contextd.*.plist; do
    [ -f "$plist" ] || continue
    name=$(basename "$plist")

    # Unload if already loaded (ignore errors for agents not yet loaded)
    launchctl unload "$LAUNCHD_DIR/$name" 2>/dev/null || true

    # Copy plist to LaunchAgents
    cp "$plist" "$LAUNCHD_DIR/"

    # Load the agent
    launchctl load "$LAUNCHD_DIR/$name"

    echo -e "  ${GREEN}Installed: $name${RESET}"
    installed=$((installed + 1))
done

if [ "$installed" -eq 0 ]; then
    echo -e "${RED}No plists found in $SRC_DIR${RESET}"
    exit 1
fi

echo ""
echo -e "${GREEN}All $installed launchd agents installed.${RESET}"
echo -e "contextd will auto-start on login."
echo ""
echo "To verify:"
echo "  launchctl list | grep contextd"
echo ""
echo "To remove:"
echo "  ./scripts/install-launchd.sh --remove"
