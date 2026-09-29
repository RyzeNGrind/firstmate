#!/usr/bin/env bash
# Vercel deployment quota probe.
# Returns JSON: {provider, tier, monthly_limit, used, remaining, reset_at, cred_source}
# Requires VERCEL_TOKEN env var.

set -u

PROVIDER="vercel"
REQUIRED_CREDS="VERCEL_TOKEN"

# Check credentials
if [ -z "${VERCEL_TOKEN:-}" ]; then
  echo '{"error": "vercel_token_not_set", "provider": "'$PROVIDER'"}' >&2
  exit 1
fi

# Try the Vercel API to get account/billing info
# Docs: https://vercel.com/docs/rest-api/endpoints#get-account-info
RESPONSE=$(timeout 5 curl -s -H "Authorization: Bearer $VERCEL_TOKEN" \
  "https://api.vercel.com/v3/user" 2>/dev/null) || {
  echo '{"error": "vercel_api_call_failed", "provider": "'$PROVIDER'"}' >&2
  exit 1
}

# Parse response
PLAN=$(jq -r '.plan // "free"' <<< "$RESPONSE" 2>/dev/null || echo "free")
TEAM_PLAN=$(jq -r '.teams[0].planId // .plan // "free"' <<< "$RESPONSE" 2>/dev/null || echo "free")

# Vercel free tier: 6000 function invocations per month
# Pro tier: 10,000 / month
# Conservative default: 6000 for free tier
PLAN_LIMIT=6000
[ "$TEAM_PLAN" = "pro" ] && PLAN_LIMIT=10000
[ "$TEAM_PLAN" = "enterprise" ] && PLAN_LIMIT=50000

jq -n \
  --arg provider "$PROVIDER" \
  --arg tier "$PLAN_LIMIT" \
  '{
    provider: $provider,
    tier: ($tier == "6000" | if . then "free" else "pro" end),
    monthly_limit: ($tier | tonumber),
    used: 0,
    remaining: ($tier | tonumber),
    reset_at: null,
    cred_source: "vercel:api:token",
    note: "usage_not_currently_queried_from_api"
  }'
