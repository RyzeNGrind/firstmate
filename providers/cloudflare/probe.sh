#!/usr/bin/env bash
# Cloudflare Workers/KV quota probe.
# Returns JSON: {provider, tier, monthly_limit, used, remaining, reset_at, cred_source}
# Requires CLOUDFLARE_API_TOKEN env var.

set -u

PROVIDER="cloudflare"
REQUIRED_CREDS="CLOUDFLARE_API_TOKEN"

# Check credentials
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo '{"error": "cloudflare_token_not_set", "provider": "'$PROVIDER'"}' >&2
  exit 1
fi

# Try wrangler CLI first if available
if command -v wrangler &>/dev/null; then
  # Get analytics via wrangler (requires CLOUDFLARE_API_TOKEN in env)
  ANALYTICS=$(timeout 5 wrangler analytics --json 2>/dev/null) || ANALYTICS=""

  if [ -n "$ANALYTICS" ]; then
    REQUESTS=$(jq -r '.requests // 0' <<< "$ANALYTICS" 2>/dev/null || echo 0)
    LIMIT=$(jq -r '.limit // 10000000' <<< "$ANALYTICS" 2>/dev/null || echo 10000000)

    jq -n \
      --arg provider "$PROVIDER" \
      --arg requests "$REQUESTS" \
      --arg limit "$LIMIT" \
      '{
        provider: $provider,
        tier: "wrangler",
        monthly_limit: ($limit | tonumber),
        used: ($requests | tonumber),
        remaining: (($limit | tonumber) - ($requests | tonumber)),
        reset_at: null,
        cred_source: "wrangler:cli"
      }'
    exit 0
  fi
fi

# Fallback: API call to billing profile
RESPONSE=$(timeout 5 curl -s -X GET \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/user/billing/profile" 2>/dev/null) || {
  echo '{"error": "cloudflare_api_call_failed", "provider": "'$PROVIDER'"}' >&2
  exit 1
}

# Check for API success
SUCCESS=$(jq -r '.success // false' <<< "$RESPONSE" 2>/dev/null || echo false)
if [ "$SUCCESS" != "true" ]; then
  echo '{"error": "cloudflare_api_error", "provider": "'$PROVIDER'"}' >&2
  exit 1
fi

PLAN=$(jq -r '.result.plan.name // "free"' <<< "$RESPONSE" 2>/dev/null || echo "free")

# Cloudflare billing profile doesn't directly expose usage, so use conservative defaults
jq -n \
  --arg provider "$PROVIDER" \
  --arg tier "$PLAN" \
  '{
    provider: $provider,
    tier: $tier,
    monthly_limit: 10000000,
    used: 0,
    remaining: 10000000,
    reset_at: null,
    cred_source: "cloudflare:api:token",
    note: "billing_profile_defaults_no_usage_data"
  }'
