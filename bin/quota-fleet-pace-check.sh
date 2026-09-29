#!/usr/bin/env bash
# Warn if any tracked provider quota drops below warn threshold.
# Called before tool use; must never block work.
# Always exits 0 to fail-open on errors.

set -u

WARN_AT=${1:-20}  # Warn at X% remaining
CACHE_MAX_AGE=300  # Reuse quota snapshot if younger than 5 min

# Try to use cached snapshot from last quota check
SNAPSHOT_FILE="${XDG_RUNTIME_DIR:-/tmp}/quota-fleet-snapshot.json"
SNAPSHOT=""

if [ -f "$SNAPSHOT_FILE" ]; then
  MTIME=$(stat -c %Y "$SNAPSHOT_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE=$((NOW - MTIME))
  if [ "$AGE" -lt "$CACHE_MAX_AGE" ]; then
    SNAPSHOT=$(cat "$SNAPSHOT_FILE" 2>/dev/null) || true
  fi
fi

# If no valid cache, run fresh probe (with timeout)
if [ -z "${SNAPSHOT:-}" ]; then
  SNAPSHOT=$(timeout 3 quota-axi --json --max-age 60 2>/dev/null) || SNAPSHOT="{}"
  # Cache for next hook invocation
  mkdir -p "$(dirname "$SNAPSHOT_FILE")" 2>/dev/null || true
  echo "$SNAPSHOT" > "$SNAPSHOT_FILE" 2>/dev/null || true
fi

# Parse and warn (fail-open on parse errors)
printf '%s\n' "$SNAPSHOT" | jq -r '.providers[] |
  select(.quotaSemantics.status == "known") |
  select(.quotaSemantics.effectiveAvailability[0].effectivePercentRemaining < '$WARN_AT') |
  "⚠️  \(.provider): \(.quotaSemantics.effectiveAvailability[0].effectivePercentRemaining)% remaining"
' 2>/dev/null || true

# Always exit 0 to never block tool use
exit 0
