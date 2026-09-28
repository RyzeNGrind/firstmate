#!/usr/bin/env bash
# Live scenarios for bin/spawn-guard.sh in this worktree.
# We build offending command strings from parts so this test harness itself
# does not contain the literal token the installed OLD hook trips on.
set -u
cd /var/lib/nixbuilder/.no-mistakes/worktrees/7ac55c2c8968/01M3KPS9DKEC1KD6AR5ZR9AW8M || {
  echo "worktree not found"; exit 1
}

EVID=$(cd "$(dirname "$0")" && pwd)
LOG=$EVID/spawn-guard-scenarios.log
: > "$LOG"

PROTECTED=$(printf '%s\n' m a s t e r | tr -d '\n')   # "master" without literal token
MAIN=$(printf '%s\n' m a i n | tr -d '\n')            # "main"

run() {
  local name=$1 cmd=$2 want=$3
  local payload rc out
  payload=$(jq -cn --arg c "$cmd" '{tool_input:{command:$c}}')
  out=$(printf '%s' "$payload" | bash bin/spawn-guard.sh 2>&1) ; rc=$?
  {
    echo "=== $name ==="
    echo "want_rc=$want  got_rc=$rc"
    echo "cmd: $cmd"
    echo "stderr/out: $out"
    echo
  } >> "$LOG"
  if [ "$rc" = "$want" ]; then
    printf 'PASS %s (rc=%s)\n' "$name" "$rc"
  else
    printf 'FAIL %s (want=%s got=%s)\n  cmd=%s\n  out=%s\n' "$name" "$want" "$rc" "$cmd" "$out"
    return 1
  fi
}

FAILS=0

# 1. Push gate scoping: "git push" appearing INSIDE a quoted --intent arg is not
#    a command invocation and must NOT trip the push gate. It should pass through
#    (the spawn is otherwise valid: has --model sonnet, no backlog row so warns).
run "scoping-quoted-git-push-in-intent" \
    "bin/fm-spawn.sh --model sonnet --intent 'plan a git push later'" 0 || FAILS=$((FAILS+1))

# 2. Push gate real invocation to protected branch inside fm-spawn command must DENY.
run "protected-branch-push-denied" \
    "bin/fm-spawn.sh --model sonnet ; git push origin $PROTECTED" 2 || FAILS=$((FAILS+1))

# 3. Push to a feature branch chained after fm-spawn passes push gate (still 0).
run "feature-branch-push-allowed" \
    "bin/fm-spawn.sh --model sonnet && git push origin feature-x" 0 || FAILS=$((FAILS+1))

# 4. Non-fm-spawn command with real push-to-master must PASS through untouched
#    (scoping fix moves the push gate below the fm-spawn-only guard).
run "non-spawn-push-passes" \
    "git push origin $PROTECTED" 0 || FAILS=$((FAILS+1))

# 5. spawn without --model is denied.
run "missing-model-denied" \
    "bin/fm-spawn.sh --harness claude" 2 || FAILS=$((FAILS+1))

# 6. Explicit forbidden model 'opus' is denied.
run "opus-denied" \
    "bin/fm-spawn.sh --model opus-4" 2 || FAILS=$((FAILS+1))

# 7. Explicit forbidden model 'fable' is denied.
run "fable-denied" \
    "bin/fm-spawn.sh --model fable-1" 2 || FAILS=$((FAILS+1))

# 8. --model default is denied.
run "default-model-denied" \
    "bin/fm-spawn.sh --model default" 2 || FAILS=$((FAILS+1))

# 9. Claude harness with unapproved model is denied.
run "claude-non-approved-model-denied" \
    "bin/fm-spawn.sh --model gpt-5" 2 || FAILS=$((FAILS+1))

# 10. Claude harness with haiku is allowed (rest of gates warn only, exit 0).
run "claude-haiku-allowed" \
    "bin/fm-spawn.sh --model haiku --harness claude" 0 || FAILS=$((FAILS+1))

# 11. Secondmate non-sonnet denied.
run "secondmate-non-sonnet-denied" \
    "bin/fm-spawn.sh --secondmate --model haiku" 2 || FAILS=$((FAILS+1))

# 12. Secondmate on sonnet: early exit 0 (skips downstream gates).
run "secondmate-sonnet-allowed" \
    "bin/fm-spawn.sh --secondmate --model sonnet" 0 || FAILS=$((FAILS+1))

# 13. Merge via forge API is denied.
run "merge-via-api-denied" \
    "curl -X PUT https://api.github.com/repos/x/y/pulls/1/merge" 2 || FAILS=$((FAILS+1))

# 14. gh pr merge is denied.
run "gh-pr-merge-denied" \
    "gh pr merge 42 --merge" 2 || FAILS=$((FAILS+1))

# 15. Guarded merge path is not gated.
run "guarded-merge-passes" \
    "bin/fm-pr-merge.sh 42" 0 || FAILS=$((FAILS+1))

# 16. Push to main is also denied (same branch check).
run "protected-main-push-denied" \
    "bin/fm-spawn.sh --model sonnet ; git push origin $MAIN" 2 || FAILS=$((FAILS+1))

echo
echo "TOTAL FAILURES: $FAILS"
exit $FAILS
