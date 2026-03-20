#!/usr/bin/env bash
# session-context.sh - Claude Code SessionStart hook for contextd
#
# Fetches recent screen activity summaries from contextd and outputs
# them as a markdown context block. Designed for graceful degradation:
# if contextd is not running, outputs nothing.
#
# Must complete in under 5 seconds total.

set -euo pipefail

CONTEXTD_URL="http://localhost:21890"
CURL_TIMEOUT=1
OVERALL_TIMEOUT=4

# Check if contextd is reachable (1s timeout on health endpoint)
if ! curl -sf --max-time "$CURL_TIMEOUT" "$CONTEXTD_URL/health" >/dev/null 2>&1; then
    exit 0
fi

# Fetch last 30 minutes of summaries (capped at 10)
response=$(curl -sf --max-time "$OVERALL_TIMEOUT" \
    "$CONTEXTD_URL/v1/summaries?minutes=30&limit=10" 2>/dev/null) || exit 0

# Bail if empty or missing data
if [ -z "$response" ]; then
    exit 0
fi

# Parse and format as markdown using Python (available on macOS)
python3 -c "
import json, sys

try:
    data = json.loads(sys.argv[1])
except (json.JSONDecodeError, IndexError):
    sys.exit(0)

summaries = data if isinstance(data, list) else data.get('summaries', data.get('data', []))
if not summaries:
    sys.exit(0)

print('## Recent Screen Activity (last 30 min)')
print()
for s in summaries:
    ts = s.get('timestamp', s.get('created_at', 'unknown'))
    app = s.get('app', s.get('application', ''))
    text = s.get('summary', s.get('text', ''))
    if not text:
        continue
    prefix = f'**{ts}**'
    if app:
        prefix += f' ({app})'
    print(f'- {prefix}: {text}')
print()
" "$response" 2>/dev/null || exit 0
