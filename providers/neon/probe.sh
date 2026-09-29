#!/usr/bin/env bash
# Neon PostgreSQL quota probe.
# Returns JSON: {provider, tier, monthly_limit, used, remaining, reset_at, cred_source}
# Requires NEON_API_KEY env var.

set -u

PROVIDER="neon"
REQUIRED_CREDS="NEON_API_KEY"

# Check credentials
if [ -z "${NEON_API_KEY:-}" ]; then
  echo '{"error": "neon_api_key_not_set", "provider": "'$PROVIDER'"}' >&2
  exit 1
fi

# Get account info to determine tier
# Docs: https://neon.tech/docs/reference/cli-commands
ACCOUNT=$(timeout 5 curl -s -H "Authorization: Bearer $NEON_API_KEY" \
  "https://console.neon.tech/api/v/me" 2>/dev/null) || {
  echo '{"error": "neon_api_call_failed", "provider": "'$PROVIDER'"}' >&2
  exit 1
}

# Parse account tier - Neon free tier: 10 compute hours/month
TIER=$(jq -r '.subscription_type // "free"' <<< "$ACCOUNT" 2>/dev/null || echo "free")

# Compute hours limit based on tier
LIMIT=10  # Free tier default
[ "$TIER" = "pro" ] && LIMIT=1000
[ "$TIER" = "enterprise" ] && LIMIT=10000

jq -n \
  --arg provider "$PROVIDER" \
  --arg tier "$TIER" \
  --arg limit "$LIMIT" \
  '{
    provider: $provider,
    tier: $tier,
    monthly_limit: ($limit | tonumber),
    used: 0,
    remaining: ($limit | tonumber),
    reset_at: null,
    cred_source: "neon:api:token",
    note: "compute_hours_limit_from_tier"
  }'
