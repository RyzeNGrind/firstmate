#!/usr/bin/env bash
# quota-gate.sh — turn quota-axi's all_models percentage into a dispatch verdict.
#
#   quota-gate.sh            prints one line and sets the exit status:
#     ALLOW cap=<n> pct=<p>     exit 0   (n = max concurrent crewmates per mate)
#     DENY  pct=<p>             exit 3   (< no_new_spawns_below_percent: no new spawns)
#     UNKNOWN cap=1 reason=...  exit 0   (quota unreadable: fail conservative, 1 crew)
#
# Thresholds come from the home's config/crew-dispatch.json `limits` block, so the
# policy lives in configuration; built-in fallbacks match the captain's ask of
# 2026-09-25 (deny < 30, cap 2 below 60).
set -u
here=$(cd "$(dirname "$0")" && pwd)
cfg=${FM_HOME:+$FM_HOME/config/crew-dispatch.json}
[ -r "${cfg:-/nonexistent}" ] || cfg="$here/../crew-dispatch.json"
lim() { jq -r --arg k "$1" --arg d "$2" '.limits[$k] // $d' "$cfg" 2>/dev/null || printf '%s' "$2"; }

# Built-in default is 0, NOT 30: the captain removed the spend floor on 2026-09-26, and a
# non-zero default meant an unresolvable config silently restored it and hard-denied every
# spawn - a fleet stall, which the standing order forbids outright.
deny_below=$(lim no_new_spawns_below_percent 0)
cap_below=$(lim capped_below_percent 60)
cap_low=$(lim max_concurrent_crewmates_when_capped 2)
cap_high=$(lim max_concurrent_crewmates_when_healthy 3)
provider=$(lim quota_provider claude)
scope=$(lim quota_scope all_models)

json=$(timeout 30 quota-axi --json 2>/dev/null) || { echo "UNKNOWN cap=1 reason=quota-axi-failed"; exit 0; }
pct=$(printf '%s' "$json" | jq -r --arg p "$provider" --arg s "$scope" '
  [.providers[]? | select(.provider == $p)
   | .quotaSemantics.effectiveAvailability[]? | select(.scope == $s and .status == "known")
   | .effectivePercentRemaining] | min // empty' 2>/dev/null)
# quota-axi intermittently marks availability "unknown" while still publishing a real
# percentRemaining. Requiring status=="known" made the cap oscillate 2<->1 and throttled
# the fleet on a reporting quirk rather than on actual headroom. Fall back to the most
# conservative real number the provider reports before giving up.
if [ -z "$pct" ]; then
  pct=$(printf '%s' "$json" | jq -r --arg p "$provider" '
    [.providers[]? | select(.provider == $p) | .. | objects | .percentRemaining?]
    | map(select(type == "number")) | min // empty' 2>/dev/null)
  [ -n "$pct" ] && degraded=" degraded=percentRemaining-fallback"
fi
degraded=${degraded:-}
if [ -z "$pct" ]; then echo "UNKNOWN cap=1 reason=no-$provider-$scope-row"; exit 0; fi

if awk -v a="$pct" -v b="$deny_below" 'BEGIN{exit !(a<b)}'; then
  echo "DENY pct=$pct$degraded"; exit 3
fi
if awk -v a="$pct" -v b="$cap_below" 'BEGIN{exit !(a<b)}'; then
  echo "ALLOW cap=$cap_low pct=$pct$degraded"
else
  echo "ALLOW cap=$cap_high pct=$pct$degraded"
fi
