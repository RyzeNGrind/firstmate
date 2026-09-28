#!/usr/bin/env bash
# finish-gate.sh - gate 5, night order §14: every task carries a machine-checkable
# finish condition, and dispatch is refused without one.
#
#   FINISH: pr <repo> | file <path> | cmd <shell> | branch <repo> <branch>
#
# These four kinds are deliberately the only ones: each is checkable by a machine
# with no judgement and no prose. "Improve X" is not a finish condition; it is how
# work becomes unlandable.
#
#   finish-gate.sh check  <home> <task-id>   exit 0 = condition DECLARED, 1 = missing
#   finish-gate.sh verify <home> <task-id>   exit 0 = condition MET
#   finish-gate.sh show   <home> <task-id>   print the condition line
set -u
act=${1:-}; home=${2:-}; task=${3:-}
[ -n "$act" ] && [ -n "$home" ] && [ -n "$task" ] || { echo "usage: finish-gate.sh check|verify|show <home> <task-id>" >&2; exit 2; }

# A condition may be declared inline on the backlog row or on its own line in the brief.
cond=""
bl="$home/data/backlog.md"
[ -f "$bl" ] && cond=$(grep -E "^- \[.\] ${task}( |$)" "$bl" 2>/dev/null | grep -oE 'FINISH:[^)]*' | head -1)
if [ -z "$cond" ]; then
  for f in "$home/data/$task/brief.md" "$home/data/$task/report.md"; do
    [ -f "$f" ] || continue
    cond=$(grep -E '^[[:space:]]*FINISH:' "$f" 2>/dev/null | head -1)
    [ -n "$cond" ] && break
  done
fi
cond=$(printf '%s' "$cond" | sed -E 's/^[[:space:]]*FINISH:[[:space:]]*//; s/[[:space:]]*$//')

case "$act" in
  show)  [ -n "$cond" ] && { printf '%s\n' "$cond"; exit 0; }; echo "(none declared)"; exit 1 ;;
  check) [ -n "$cond" ] && exit 0
         printf 'no finish condition declared for %s\n' "$task" >&2; exit 1 ;;
esac

# verify
[ -n "$cond" ] || { echo "UNDECLARED"; exit 1; }
# shellcheck disable=SC2086
set -- $cond
kind=${1:-}; shift || true
case "$kind" in
  file)   [ -e "${1:-}" ] && { echo "MET"; exit 0; }; echo "NOT-MET: no such path ${1:-}"; exit 1 ;;
  cmd)    if eval "$*" >/dev/null 2>&1; then echo "MET"; exit 0; fi; echo "NOT-MET: command non-zero"; exit 1 ;;
  branch) if git -C "$home/projects/$(basename "${1:-}")" rev-parse --verify "origin/${2:-}" >/dev/null 2>&1; then echo "MET"; exit 0; fi
          echo "NOT-MET: origin/${2:-} absent"; exit 1 ;;
  pr)     # MET means a PR exists FOR THIS TASK, recorded as pr= in its durable metadata.
          # Listing the repo is NOT proof: an empty repo lists fine and would report MET on
          # work that never shipped. PR numbers also collide across forges (GitHub #4 and
          # Forgejo #4 are different PRs), so only the task's own recorded URL is authority.
          meta="$home/state/$task.meta"
          if [ -f "$meta" ]; then
            pr=$(grep -E '^pr=' "$meta" 2>/dev/null | head -1 | cut -d= -f2-)
            if [ -n "$pr" ]; then echo "MET pr=$pr"; exit 0; fi
          fi
          echo "NOT-MET: no pr= recorded for $task (open the PR, then register it)"; exit 1 ;;
  *)      echo "NOT-MET: unknown finish kind '$kind'"; exit 1 ;;
esac
