#!/usr/bin/env bash
# spawn-guard.sh — Claude Code PreToolUse hook (matcher: Bash) for the OCI deputy home.
# Makes the model-routing and usage policy MECHANICAL: a `fm-spawn.sh` invocation that
# violates it is blocked (exit 2, reason on stderr) before it runs.
#
# Enforced (limits live in config/crew-dispatch.json `limits`):
#   * every spawn names an explicit --model; never `default`, `opus` or `fable`
#   * crewmates/scouts: claude models must be haiku or sonnet
#   * secondmate agents: sonnet
#   * quota-axi all_models < no_new_spawns_below_percent  -> no new spawn
#   * live crewmates for this mate >= cap (2 below 60 %, else the healthy cap) -> wait
#   * root filesystem (/) usage must be <= 85%
# Anything that is not an fm-spawn.sh call passes untouched.
set -u
here=$(cd "$(dirname "$0")" && pwd)
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
deny() { printf 'spawn-guard: %s\n' "$1" >&2; exit 2; }

# ---- gate 6: MERGE AUTHORITY (hard rule 2) -------------------------------------------
# 2026-09-26: a deputy merged nixify PR#29 straight to master via the forge, bypassing the
# guarded merge path, with no captain word and no authority record. Detection after the fact
# is useless for a merge - master had already moved. So the merge ACTION is now gated.
# The guarded scripts are the only permitted path because they alone record authority and
# refuse an unproved merge. Reads of a PR are untouched; only merge actions are refused.
case "$cmd" in
  *fm-pr-merge.sh*|*fm-merge-local.sh*) ;;                 # guarded paths own their own checks
  *"pr merge"*|*"pulls/"*"/merge"*|*"pulls/"*"/merge\""*)
      deny "MERGE REFUSED - hard rule 2. Merging a PR needs the captain's explicit word, and it must
  go through bin/fm-pr-merge.sh, which records the authority and refuses an unproved merge.
  A direct forge merge leaves no authority record and cannot be undone by a gate afterwards.
  If the captain has given the word for this exact PR, use fm-pr-merge.sh so it is recorded." ;;
esac
case "$cmd" in *fm-spawn.sh*) ;; *) exit 0 ;; esac

if printf '%s' "$cmd" | grep -qE '(^|;[[:space:]]*|&&[[:space:]]*|\|\|[[:space:]]*)git[[:space:]]+push[[:space:]]'; then
  case "$cmd" in
    *" master"*|*" main"*|*":master"*|*":main"*|*"HEAD:master"*|*"HEAD:main"*)
        deny "PUSH TO A PROTECTED BRANCH REFUSED. master/main are operator-protected: agents
  never push there. Open a PR and let the captain merge it." ;;
  esac
fi

model=$(printf '%s' "$cmd" | sed -nE 's/.*--model[= ]+([^ ]+).*/\1/p' | head -1)
[ -n "$model" ] || deny "spawn without an explicit --model (model=default is forbidden). Resolve a profile from config/crew-dispatch.json and pass --model."
case "$model" in
  default|*opus*|*fable*|*Opus*|*Fable*) deny "model '$model' is forbidden for agents on this host (never default/opus/fable)." ;;
esac
harness=$(printf '%s' "$cmd" | sed -nE 's/.*--harness[= ]+([^ ]+).*/\1/p' | head -1)
if [ -z "$harness" ] || [ "$harness" = claude ]; then
  case "$model" in
    *sonnet*|*haiku*) ;;
    *) deny "claude model '$model' not allowed: workers use haiku (mechanical/read-only) or sonnet; secondmates sonnet." ;;
  esac
fi
case "$cmd" in
  *--secondmate*)
    case "$model" in *sonnet*) ;; *) deny "secondmates run on sonnet, not '$model'." ;; esac
    # Secondmates are persistent homes, not crews/tasks. Disk and concurrency gates apply to
    # crewmates and scouts only, not to secondmate spawns which run in their own home.
    exit 0 ;;
esac

verdict=$("$here/quota-gate.sh")
case "$verdict" in
  DENY*) deny "quota gate closed ($verdict): no new spawns below the configured all_models floor; consult quota-axi and wait for reset." ;;
esac
cap=$(printf '%s' "$verdict" | sed -nE 's/.*cap=([0-9]+).*/\1/p')
cap=${cap:-1}
home=${FM_HOME:-$(cd "$here/../.." && pwd)}

# gate 4 / night order §3: disk rule on alpha - no spawn while / is above 85%.
disk_used=$(df -P / 2>/dev/null | awk 'NR==2{print $(NF-1)}' | sed 's/%//')
if [ -n "$disk_used" ] && awk -v used="$disk_used" 'BEGIN{exit !(used > 85)}'; then
  deny "disk full gate: / is $disk_used% full (>85% threshold). Tear down landed crews and retry."
fi

# gate 5 / night order §14: no dispatch without a machine-checkable finish condition.
# Denies only when the row is FOUND and carries no condition - an unresolvable task id
# warns and passes, because a gate that blocks every spawn on a lookup mismatch would
# stall the fleet, which is the one outcome the standing order forbids outright.
task=""
# shellcheck disable=SC2086
set -- $cmd
for tok in "$@"; do
  case "$tok" in -*|*fm-spawn.sh|*/*|*=*) continue ;; esac
  if grep -qE "^- \[.\] ${tok}( |$)" "$home/data/backlog.md" 2>/dev/null || [ -d "$home/data/$tok" ]; then
    task="$tok"; break
  fi
done
# Fallback: a supervisor relaunched without FM_HOME would otherwise degrade this gate
# to a warning. Task ids are unique fleet-wide, so resolve the owning home by search.
if [ -z "$task" ]; then
  # shellcheck disable=SC2086
  set -- $cmd
  for tok in "$@"; do
    case "$tok" in -*|*fm-spawn.sh|*/*|*=*) continue ;; esac
    for cand in /var/lib/firstmate/homes/*/; do
      if grep -qE "^- \[.\] ${tok}( |$)" "$cand/data/backlog.md" 2>/dev/null || [ -d "$cand/data/$tok" ]; then
        task="$tok"; home="${cand%/}"; break 2
      fi
    done
  done
fi
if [ -n "$task" ] && [ -x "$here/finish-gate.sh" ]; then
  if ! "$here/finish-gate.sh" check "$home" "$task" 2>/dev/null; then
    deny "task '$task' has no machine-checkable finish condition. Add one line to its row or brief, then respawn:
    FINISH: pr <repo> | file <path> | cmd <shell> | branch <repo> <branch>
  If the finish cannot be written as one of those four, the task is too vague or too large - split it."
  fi
elif [ -z "$task" ]; then
  printf 'spawn-guard: warn: no backlog row resolved from this spawn; finish condition unverified\n' >&2
fi
live=0
for m in "$home"/state/*.meta; do
  [ -e "$m" ] || continue
  grep -Eq '^kind=(ship|scout)$' "$m" || continue
  # The cap limits ACTIVE COMPUTE. A task that has already delivered its PR is parked waiting
  # on a merge decision and consumes nothing, so counting it throttles the fleet behind the
  # merge queue: on 2026-09-26, 5 of 6 slots fleet-wide were held by delivered PRs and no new
  # work could start at all. Delivery is proven by a recorded pr= URL; nothing is torn down.
  grep -Eq '^pr=https?://' "$m" 2>/dev/null && continue
  live=$((live + 1))
done
[ "$live" -lt "$cap" ] || deny "concurrency cap reached: $live live crewmates >= cap $cap ($verdict). Wait for one to finish."
exit 0
