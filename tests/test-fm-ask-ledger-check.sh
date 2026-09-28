#!/usr/bin/env bash
# Simple shell test for fm-ask-ledger-check.sh

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_count=0
pass_count=0

assert_eq() {  # <actual> <expected> <description>
  test_count=$((test_count + 1))
  if [ "$1" = "$2" ]; then
    echo "✓ $3"
    pass_count=$((pass_count + 1))
  else
    echo "✗ $3"
    echo "  Expected: $2"
    echo "  Got: $1"
  fi
}

assert_contains() {  # <haystack> <needle> <description>
  test_count=$((test_count + 1))
  if [[ "$1" == *"$2"* ]]; then
    echo "✓ $3"
    pass_count=$((pass_count + 1))
  else
    echo "✗ $3"
    echo "  Expected to contain: $2"
    echo "  Got: $1"
  fi
}

assert_not_empty() {  # <value> <description>
  test_count=$((test_count + 1))
  if [ -n "$1" ]; then
    echo "✓ $3"
    pass_count=$((pass_count + 1))
  else
    echo "✗ $2"
  fi
}

setup() {
  TEST_HOME=$(mktemp -d)
  TEST_STATE="$TEST_HOME/state"
  TEST_DATA="$TEST_HOME/data"
  mkdir -p "$TEST_STATE" "$TEST_DATA"
  mkdir -p "$TEST_STATE/inbox"
  touch "$TEST_DATA/backlog.md"
}

teardown() {
  [ -n "$TEST_HOME" ] && [ -d "$TEST_HOME" ] && rm -rf "$TEST_HOME"
}

test_detects_unreconciled() {
  setup

  # Create a CAPTAIN ASK note
  {
    printf 'id=test-ask-001\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf '%s\n' '--'
    printf 'Test question\n'
  } >"$TEST_STATE/inbox/test-ask-001.note"

  # Run check
  output=$(FM_HOME="$TEST_HOME" FM_STATE_OVERRIDE="$TEST_STATE" FM_DATA_OVERRIDE="$TEST_DATA" \
    "$SCRIPT_DIR/fm-ask-ledger-check.sh" check)

  assert_contains "$output" "test-ask-001" "Detects unreconciled CAPTAIN ASK note"

  teardown
}

test_ignores_non_captain() {
  setup

  # Create a non-CAPTAIN note
  {
    printf 'id=some-note-001\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=user\n'
    printf 'announce_marker=1\n'
    printf '%s\n' '--'
    printf 'Some note\n'
  } >"$TEST_STATE/inbox/some-note-001.note"

  # Run check
  output=$(FM_HOME="$TEST_HOME" FM_STATE_OVERRIDE="$TEST_STATE" FM_DATA_OVERRIDE="$TEST_DATA" \
    "$SCRIPT_DIR/fm-ask-ledger-check.sh" check)

  assert_eq "$output" "" "Ignores non-CAPTAIN ASK notes"

  teardown
}

test_reconciles_in_backlog() {
  setup

  # Create a CAPTAIN ASK note
  {
    printf 'id=test-ask-002\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf '%s\n' '--'
    printf 'Question in backlog\n'
  } >"$TEST_STATE/inbox/test-ask-002.note"

  # Add to backlog
  cat > "$TEST_DATA/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] test-ask-002 - some task
EOF

  # Run check
  output=$(FM_HOME="$TEST_HOME" FM_STATE_OVERRIDE="$TEST_STATE" FM_DATA_OVERRIDE="$TEST_DATA" \
    "$SCRIPT_DIR/fm-ask-ledger-check.sh" check)

  assert_eq "$output" "" "Reconciles when ask is in backlog"

  teardown
}

test_dedup() {
  setup

  # Create a CAPTAIN ASK note
  {
    printf 'id=test-ask-003\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf '%s\n' '--'
    printf 'Test for dedup\n'
  } >"$TEST_STATE/inbox/test-ask-003.note"

  # First check
  output1=$(FM_HOME="$TEST_HOME" FM_STATE_OVERRIDE="$TEST_STATE" FM_DATA_OVERRIDE="$TEST_DATA" \
    "$SCRIPT_DIR/fm-ask-ledger-check.sh" check)
  assert_contains "$output1" "test-ask-003" "First check reports unreconciled"

  # Second check should be silent (already reported)
  output2=$(FM_HOME="$TEST_HOME" FM_STATE_OVERRIDE="$TEST_STATE" FM_DATA_OVERRIDE="$TEST_DATA" \
    "$SCRIPT_DIR/fm-ask-ledger-check.sh" check)
  assert_eq "$output2" "" "Deduplicates repeated checks"

  teardown
}

test_empty_inbox() {
  setup

  # Remove inbox
  rm -rf "$TEST_STATE/inbox"

  # Run check
  output=$(FM_HOME="$TEST_HOME" FM_STATE_OVERRIDE="$TEST_STATE" FM_DATA_OVERRIDE="$TEST_DATA" \
    "$SCRIPT_DIR/fm-ask-ledger-check.sh" check)

  assert_eq "$output" "" "Handles empty inbox gracefully"

  teardown
}

test_multiple_asks() {
  setup

  # Create multiple CAPTAIN ASK notes
  {
    printf 'id=ask-a\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf '%s\n' '--'
    printf 'First ask\n'
  } >"$TEST_STATE/inbox/ask-a.note"

  {
    printf 'id=ask-b\n'
    printf 'at=2026-09-28T10:01:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf '%s\n' '--'
    printf 'Second ask\n'
  } >"$TEST_STATE/inbox/ask-b.note"

  # Run check
  output=$(FM_HOME="$TEST_HOME" FM_STATE_OVERRIDE="$TEST_STATE" FM_DATA_OVERRIDE="$TEST_DATA" \
    "$SCRIPT_DIR/fm-ask-ledger-check.sh" check)

  assert_contains "$output" "ask-a" "Reports multiple unreconciled asks (ask-a)"
  assert_contains "$output" "ask-b" "Reports multiple unreconciled asks (ask-b)"

  teardown
}

# Run tests
echo "Running fm-ask-ledger-check tests..."
echo

test_detects_unreconciled
test_ignores_non_captain
test_reconciles_in_backlog
test_dedup
test_empty_inbox
test_multiple_asks

echo
echo "Results: $pass_count/$test_count passed"
[ $pass_count -eq $test_count ] && exit 0 || exit 1
