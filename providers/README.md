# Fleet Quota Probes

Auto-discovery multi-tool quota/usage probes for the firstmate fleet. Each provider is a standalone shell script that returns structured JSON quota data.

## Design Principles

1. **Zero hardcoding:** Each provider is a probe script; discovery engine finds and runs only those whose credentials are present
2. **Read-only:** GET requests only, never write or consume quotas
3. **Fail-open:** Probe errors log but never block subsequent probes or work
4. **Conservative tier detection:** Free/trial tiers default to 0.5x runway estimate
5. **Single API call per provider:** Minimize quota burn during discovery

## How Probes Work

### Structure

Each probe is a bash script at `providers/<NAME>/probe.sh` that:

1. Declares `REQUIRED_CREDS="..."` (space-separated list of env vars or CLI tools needed)
2. Checks if all required credentials are present; exits 1 if any missing
3. Calls one read-only API endpoint to discover quota/tier
4. Returns structured JSON on stdout

### Required JSON Output Shape

Every successful probe must output exactly this JSON structure on stdout:

```json
{
  "provider": "name",
  "tier": "free|pro|enterprise|...",
  "monthly_limit": 1000,
  "used": 234,
  "remaining": 766,
  "reset_at": "2026-10-29T00:00:00Z",
  "cred_source": "cli|env:VAR_NAME|api:token"
}
```

**Field definitions:**

- `provider`: Machine-readable provider name (github, vercel, cloudflare, etc.)
- `tier`: Plan tier or account type (detect via API)
- `monthly_limit`: Hard limit per reset window (0 for unlimited)
- `used`: Current usage within the window
- `remaining`: `monthly_limit - used`
- `reset_at`: ISO8601 when quota resets, null if not applicable
- `cred_source`: Where credentials came from (for audit logging)

### Credential Declaration

The `REQUIRED_CREDS` variable tells the discovery engine which credentials to check. Format:

```bash
# Environment variables (uppercase)
REQUIRED_CREDS="GITHUB_TOKEN VERCEL_TOKEN"

# CLI tools (lowercase)
REQUIRED_CREDS="gh vercel"

# Mix of both
REQUIRED_CREDS="CLOUDFLARE_API_TOKEN wrangler"
```

The discovery engine (`bin/quota-fleet-discover.sh`) checks:
- Env vars: `[ -z "${VAR_NAME:-}" ]`
- CLI tools: `command -v tool_name`

If any required credential is missing, the probe is skipped (not run).

### Failure Handling

- **Credential missing:** Exit 1 immediately (discovery engine skips this probe)
- **API call fails:** Exit 1 and log error message to stderr (discovery logs but continues)
- **Parse error:** Exit 1 (discovery continues)
- **Never block work:** Probe errors are logged but never stop the discovery or subsequent probes

## Authoring a New Probe

### Template

```bash
#!/usr/bin/env bash
# <provider> quota probe.
# Returns JSON: {provider, tier, monthly_limit, used, remaining, reset_at, cred_source}

set -u

PROVIDER="<name>"
REQUIRED_CREDS="<env_vars_or_cli_tools>"

# 1. Check credentials
if [ -z "${TOKEN_VAR:-}" ]; then
  echo '{"error": "missing_token", "provider": "'$PROVIDER'"}' >&2
  exit 1
fi

if ! command -v cli_tool &>/dev/null; then
  echo '{"error": "cli_not_found", "provider": "'$PROVIDER'"}' >&2
  exit 1
fi

# 2. Call ONE read-only API endpoint
RESPONSE=$(timeout 5 curl -s -H "Authorization: Bearer $TOKEN_VAR" \
  "https://api.provider.com/quota" 2>/dev/null) || {
  echo '{"error": "api_call_failed", "provider": "'$PROVIDER'"}' >&2
  exit 1
}

# 3. Parse response and return JSON
jq -n \
  --arg provider "$PROVIDER" \
  --argjson resp "$RESPONSE" \
  '{
    provider: $provider,
    tier: $resp.plan,
    monthly_limit: $resp.limits.monthly,
    used: $resp.usage.current,
    remaining: ($resp.limits.monthly - $resp.usage.current),
    reset_at: $resp.window.resetsAt,
    cred_source: "api:token"
  }'
```

### Best Practices

1. **Always set `-u` (errexit + nounset)** to catch undefined variables
2. **Use `timeout 5` for API calls** to prevent hangs
3. **Log errors to stderr** (`>&2`), JSON to stdout
4. **Exit 1 on error, 0 on success** (no partial failures)
5. **Use `jq` for JSON output** to ensure valid structure
6. **Handle free/trial tiers conservatively** — default to 0.5x actual runway if uncertain
7. **Never log secrets** — check stderr for sensitive data before committing
8. **One API call only** — minimize quota burn during discovery
9. **Cache-friendly keys** — use consistent field names for aggregation

## Running Probes

### Manual (for testing)

```bash
# Run one probe directly
bash providers/github/probe.sh

# Run all probes
bash bin/quota-fleet-discover.sh
```

### Automatic (via hooks)

Discovery is called:
- **Claude Code PreToolUse hook:** `bin/quota-fleet-pace-check.sh` (every tool use)
- **Nixify devShell hook:** Warm cache on `nix develop` entry
- **Firstmate SessionStart:** (Future: log to audit trail)

## Example: GitHub Probe

See `providers/github/probe.sh` for a working example that handles:
- CLI authentication check
- Paid plan API call (with fallback)
- Free tier fallback
- Conservative estimate for free tier

## Extending the Fleet

To add a new provider:

1. Create `providers/<name>/probe.sh`
2. Declare `REQUIRED_CREDS="..."`
3. Call one read-only API
4. Return JSON in the standard shape
5. Discovery engine auto-detects and runs it next time

No changes to the discovery engine or hooks needed.

## Debugging

Check stderr for skipped probes and failures:

```bash
# Run discovery and capture diagnostics
bin/quota-fleet-discover.sh 2>&1 | tee discovery.log
```

Lines starting with `⚠️` are diagnostic messages; probe output is JSON.
