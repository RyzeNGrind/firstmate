#!/usr/bin/env bash
# GitHub Actions minutes quota probe.
# Returns JSON: {provider, tier, monthly_limit, used, remaining, reset_at, cred_source}

set -u

PROVIDER="github"
REQUIRED_CREDS="gh"

# Check credentials
if ! command -v gh &>/dev/null; then
  echo '{"error": "gh_cli_not_found", "provider": "'$PROVIDER'"}' >&2
  exit 1
fi

if ! gh auth status -h github.com &>/dev/null 2>&1; then
  echo '{"error": "gh_not_authenticated", "provider": "'$PROVIDER'"}' >&2
  exit 1
fi

# Check if user has paid plan (billing endpoint available)
BILLING=$(gh api /user/billing/actions_minutes 2>/dev/null) || {
  # Free tier or insufficient scopes; return conservative estimate
  USER=$(gh api /user 2>/dev/null || echo '{"type":"User"}')
  PLAN=$(jq -r '.type' <<< "$USER" 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "user")

  # GitHub free tier: 2000 minutes/month for private repos, unlimited public
  # Conservative: assume 1000 minutes/month (0.5x actual)
  jq -n \
    --arg provider "$PROVIDER" \
    --arg tier "${PLAN}" \
    '{
      provider: $provider,
      tier: $tier,
      monthly_limit: 1000,
      used: 0,
      remaining: 1000,
      reset_at: null,
      cred_source: "gh:cli",
      note: "free_tier_conservative_estimate"
    }'
  exit 0
}

# Parse paid plan response
jq -n \
  --arg provider "$PROVIDER" \
  --argjson billing "$BILLING" \
  '{
    provider: $provider,
    tier: "pro_or_team",
    monthly_limit: $billing.total_minutes_available,
    used: $billing.total_minutes_used,
    remaining: ($billing.total_minutes_available - $billing.total_minutes_used),
    reset_at: (now + (30 * 86400) | todate),
    cred_source: "gh:cli:authenticated"
  }'
