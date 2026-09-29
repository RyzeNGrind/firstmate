#!/usr/bin/env bash
# Warn if any tracked provider quota drops below warn threshold.
# Called before tool use; must never block work.
# Always exits 0 to fail-open on errors.

set -u

# Parse arguments properly
WARN_AT=20  # Default warn at 20% remaining
while [ $# -gt 0 ]; do
  case "$1" in
    --warn-at)
      shift
      WARN_AT="${1:-20}"
      ;;
    *)
      shift
      ;;
  esac
done

CACHE_MAX_AGE=300  # Reuse quota snapshot if younger than 5 min
CACHE_FILE="${XDG_RUNTIME_DIR:-/tmp}/quota-fleet-snapshot.json"
SNAPSHOT=""

# Try to use cached snapshot from last discovery or quota check
if [ -f "$CACHE_FILE" ]; then
  MTIME=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE=$((NOW - MTIME))
  if [ "$AGE" -lt "$CACHE_MAX_AGE" ]; then
    SNAPSHOT=$(cat "$CACHE_FILE" 2>/dev/null) || true
  fi
fi

# If cache is stale, run fresh discovery (or fallback to quota-axi)
if [ -z "${SNAPSHOT:-}" ]; then
  # Try to discover new providers if script is available
  if [ -x "${CLAUDE_PROJECT_DIR:-}/bin/quota-fleet-discover.sh" ]; then
    SNAPSHOT=$(timeout 5 "$CLAUDE_PROJECT_DIR"/bin/quota-fleet-discover.sh 2>/dev/null) || true
  fi

  # If discovery failed or unavailable, try quota-axi as fallback
  if [ -z "${SNAPSHOT:-}" ]; then
    SNAPSHOT=$(timeout 3 quota-axi --json --max-age 60 2>/dev/null) || SNAPSHOT="{}"
  fi

  # Cache for next hook invocation
  mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null || true
  echo "$SNAPSHOT" > "$CACHE_FILE" 2>/dev/null || true
fi

# Warn on low quotas from fleet discovery (if available)
if echo "$SNAPSHOT" | grep -q '"provider"'; then
  # Fleet discovery format: {generatedAt, providers: [{provider, tier, monthly_limit, used, remaining, ...}]}
  printf '%s\n' "$SNAPSHOT" | jq -r '.providers[] |
    select(.remaining != null and .monthly_limit != null and .monthly_limit > 0) |
    select((.remaining / .monthly_limit * 100) < '$WARN_AT') |
    "⚠️  Fleet: \(.provider) at \((.remaining / .monthly_limit * 100) | floor)%"
  ' 2>/dev/null || true
fi

# Also warn on low quotas from quota-axi (if available)
if echo "$SNAPSHOT" | grep -q '"effectivePercentRemaining"'; then
  # quota-axi format with effectiveAvailability
  printf '%s\n' "$SNAPSHOT" | jq -r '.providers[] |
    select(.quotaSemantics.status == "known") |
    select(.quotaSemantics.effectiveAvailability[0].effectivePercentRemaining < '$WARN_AT') |
    "⚠️  Quota: \(.provider): \(.quotaSemantics.effectiveAvailability[0].effectivePercentRemaining)% remaining"
  ' 2>/dev/null || true
fi

# Always exit 0 to never block tool use
exit 0
