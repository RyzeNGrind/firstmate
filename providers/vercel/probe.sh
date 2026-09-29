#!/usr/bin/env bash
# Vercel deployment quota probe.
# Returns JSON: {provider, tier, monthly_limit, used, remaining, reset_at, cred_source}
# Requires either vercel CLI or VERCEL_TOKEN env var.

set -u

PROVIDER="vercel"
REQUIRED_CREDS="VERCEL_TOKEN"

# Check if vercel CLI is available
if command -v vercel &>/dev/null; then
  # Try vercel CLI (requires VERCEL_TOKEN in env)
  if [ -z "${VERCEL_TOKEN:-}" ]; then
    echo '{"error": "vercel_cli_found_but_no_token", "provider": "'$PROVIDER'"}' >&2
    exit 1
  fi

  RESPONSE=$(timeout 5 vercel billing --json 2>/dev/null) || {
    echo '{"error": "vercel_cli_call_failed", "provider": "'$PROVIDER'"}' >&2
    exit 1
  }

  PLAN=$(jq -r '.plan // "unknown"' <<< "$RESPONSE" 2>/dev/null || echo "unknown")
  BUILDS_USED=$(jq -r '.usage.builds // 0' <<< "$RESPONSE" 2>/dev/null || echo 0)
  BUILDS_LIMIT=$(jq -r '.limits.builds // 1000' <<< "$RESPONSE" 2>/dev/null || echo 1000)

  jq -n \
    --arg provider "$PROVIDER" \
    --arg tier "$PLAN" \
    --arg limit "$BUILDS_LIMIT" \
    --arg used "$BUILDS_USED" \
    '{
      provider: $provider,
      tier: $tier,
      monthly_limit: ($limit | tonumber),
      used: ($used | tonumber),
      remaining: (($limit | tonumber) - ($used | tonumber)),
      reset_at: null,
      cred_source: "vercel:cli"
    }'
  exit 0
fi

# Fallback: try API with token
if [ -z "${VERCEL_TOKEN:-}" ]; then
  echo '{"error": "vercel_cli_not_found_and_no_token", "provider": "'$PROVIDER'"}' >&2
  exit 1
fi

RESPONSE=$(timeout 5 curl -s -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v2/billing" 2>/dev/null) || {
  echo '{"error": "vercel_api_call_failed", "provider": "'$PROVIDER'"}' >&2
  exit 1
}

PLAN=$(jq -r '.plan // "unknown"' <<< "$RESPONSE" 2>/dev/null || echo "unknown")
BUILDS_USED=$(jq -r '.usage.builds // 0' <<< "$RESPONSE" 2>/dev/null || echo 0)
BUILDS_LIMIT=$(jq -r '.limits.builds // 1000' <<< "$RESPONSE" 2>/dev/null || echo 1000)

jq -n \
  --arg provider "$PROVIDER" \
  --arg tier "$PLAN" \
  --arg limit "$BUILDS_LIMIT" \
  --arg used "$BUILDS_USED" \
  '{
    provider: $provider,
    tier: $tier,
    monthly_limit: ($limit | tonumber),
    used: ($used | tonumber),
    remaining: (($limit | tonumber) - ($used | tonumber)),
    reset_at: null,
    cred_source: "vercel:api:token"
  }'
