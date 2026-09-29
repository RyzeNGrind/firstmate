#!/usr/bin/env bash
# Discover quota/usage for all available fleet providers.
# Scans providers/*/probe.sh, checks REQUIRED_CREDS, runs eligible probes.
# Emits combined snapshot: {generatedAt, providers: [...]}
# Fail-open: probe errors log to stderr but never abort.

set -u

PROVIDERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../providers" && pwd)"
RESULTS=()

# Scan all probe scripts
for probe in "$PROVIDERS_DIR"/*/probe.sh; do
  [ -f "$probe" ] || continue

  provider=$(basename "$(dirname "$probe")")

  # Extract REQUIRED_CREDS declaration from probe script
  REQUIRED_CREDS=""
  REQUIRED_CREDS=$(grep -oP '(?<=REQUIRED_CREDS=")[^"]*' "$probe" 2>/dev/null || grep -oP "(?<=REQUIRED_CREDS=')[^']*" "$probe" 2>/dev/null || echo "") || true

  # Check if all required credentials are available
  if [ -n "${REQUIRED_CREDS:-}" ]; then
    all_creds_present=1
    for cred in $REQUIRED_CREDS; do
      # Check if it's an environment variable (uppercase) or CLI tool
      if [[ "$cred" =~ ^[A-Z_]+$ ]]; then
        # Environment variable
        if [ -z "${!cred:-}" ]; then
          all_creds_present=0
          break
        fi
      else
        # CLI tool
        if ! command -v "$cred" &>/dev/null; then
          all_creds_present=0
          break
        fi
      fi
    done

    if [ $all_creds_present -eq 0 ]; then
      echo "⚠️  Skipping $provider probe: missing required credentials ($REQUIRED_CREDS)" >&2
      continue
    fi
  fi

  # Run probe; fail-open on error
  result=$("$probe" 2>/dev/null) || {
    echo "⚠️  $provider probe failed (check stderr above for details)" >&2
    continue
  }

  RESULTS+=("$result")
done

# Emit combined snapshot
if [ ${#RESULTS[@]} -gt 0 ]; then
  printf '%s\n' "${RESULTS[@]}" | jq -s '{
    generatedAt: (now | todate),
    providers: .
  }' 2>/dev/null || {
    echo "⚠️  Failed to format snapshot JSON" >&2
    echo '{"generatedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","providers":[]}'
  }
else
  echo '{"generatedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","providers":[]}'
fi
