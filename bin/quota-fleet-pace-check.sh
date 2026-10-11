#!/usr/bin/env bash
# Warn if any quota-axi provider drops below the warn threshold.
# Thin wrapper around `quota-axi --json`; the provider catalogue and schema live
# in quota-axi itself. Called from Claude Code hooks; must never block work and
# always exits 0.

set -u

WARN_AT=20
while [ $# -gt 0 ]; do
  case "$1" in
    --warn-at)
      shift
      WARN_AT="${1:-20}"
      ;;
    *) ;;
  esac
  shift
done

command -v quota-axi >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SNAPSHOT=$(timeout 3 quota-axi --json --max-age 60 2>/dev/null) || exit 0
[ -n "$SNAPSHOT" ] || exit 0

printf '%s\n' "$SNAPSHOT" | jq -r --argjson warn "$WARN_AT" '
  .providers[]?
  | select(.quotaSemantics.status == "known")
  | . as $p
  | (.quotaSemantics.effectiveAvailability // [])[]?
  | select(.status == "known" and .effectivePercentRemaining < $warn)
  | "⚠️  Quota: \($p.provider) (\(.scope)) at \(.effectivePercentRemaining | floor)% remaining"
' 2>/dev/null || true

exit 0
