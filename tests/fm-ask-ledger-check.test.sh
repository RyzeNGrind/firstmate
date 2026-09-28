#!/usr/bin/env bash
# BATS tests for fm-ask-ledger-check.sh
# bats file_tags=fm-ask-ledger-check

setup_file() {
  # Source test utilities
  cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
  # shellcheck source=tests/lib.sh
  . ./lib.sh
  export BATS_TEST_SUITE_TMPDIR
}

setup() {
  TEST_HOME=$(mktemp -d)
  TEST_STATE="$TEST_HOME/state"
  TEST_DATA="$TEST_HOME/data"
  mkdir -p "$TEST_STATE" "$TEST_DATA"
  export FM_HOME="$TEST_HOME"
  export FM_STATE_OVERRIDE="$TEST_STATE"
  export FM_DATA_OVERRIDE="$TEST_DATA"

  # Create a minimal backlog
  touch "$TEST_DATA/backlog.md"

  # Create inbox directory
  mkdir -p "$TEST_STATE/inbox"
}

teardown() {
  [ -n "$TEST_HOME" ] && [ -d "$TEST_HOME" ] && rm -rf "$TEST_HOME"
}

@test "detects unreconciled CAPTAIN ASK note" {
  local SCRIPT_DIR INBOX
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
  INBOX="$TEST_STATE/inbox"

  # Create a CAPTAIN ASK note
  {
    printf 'id=test-ask-001\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf -- '--\n'
    printf 'Test question about the system\n'
  } >"$INBOX/test-ask-001.note"

  # Run check - should report unreconciled
  output=$("$SCRIPT_DIR/fm-ask-ledger-check.sh" check)
  [ -n "$output" ]
  [[ "$output" == *"test-ask-001"* ]]
}

@test "ignores non-CAPTAIN ASK notes" {
  local SCRIPT_DIR INBOX
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
  INBOX="$TEST_STATE/inbox"

  # Create a non-CAPTAIN note
  {
    printf 'id=some-note-001\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=user\n'
    printf 'announce_marker=1\n'
    printf -- '--\n'
    printf 'Some other note\n'
  } >"$INBOX/some-note-001.note"

  # Run check - should report nothing
  output=$("$SCRIPT_DIR/fm-ask-ledger-check.sh" check)
  [ -z "$output" ]
}

@test "reconciles when ask is in backlog" {
  local SCRIPT_DIR INBOX
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
  INBOX="$TEST_STATE/inbox"

  # Create a CAPTAIN ASK note
  {
    printf 'id=test-ask-002\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf -- '--\n'
    printf 'Question in backlog\n'
  } >"$INBOX/test-ask-002.note"

  # Add to backlog
  {
    printf '# Backlog\n\n'
    printf '## In flight\n'
    printf '- [ ] test-ask-002 - some task\n'
  } >"$TEST_DATA/backlog.md"

  # Run check - should report nothing
  output=$("$SCRIPT_DIR/fm-ask-ledger-check.sh" check)
  [ -z "$output" ]
}

@test "deduplicates repeated checks" {
  local SCRIPT_DIR INBOX
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
  INBOX="$TEST_STATE/inbox"

  # Create a CAPTAIN ASK note
  {
    printf 'id=test-ask-003\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf -- '--\n'
    printf 'Test for dedup\n'
  } >"$INBOX/test-ask-003.note"

  # First check - should report
  output1=$("$SCRIPT_DIR/fm-ask-ledger-check.sh" check)
  [ -n "$output1" ]

  # Second check with same state - should report nothing (idempotent)
  output2=$("$SCRIPT_DIR/fm-ask-ledger-check.sh" check)
  [ -z "$output2" ]
}

@test "handles empty inbox gracefully" {
  local SCRIPT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

  # Remove inbox if it exists
  [ -d "$TEST_STATE/inbox" ] && rm -rf "$TEST_STATE/inbox"

  # Run check - should report nothing
  output=$("$SCRIPT_DIR/fm-ask-ledger-check.sh" check)
  [ -z "$output" ]
}

@test "handles missing backlog gracefully" {
  local SCRIPT_DIR INBOX
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
  INBOX="$TEST_STATE/inbox"

  # Remove backlog
  rm -f "$TEST_DATA/backlog.md"

  # Create a CAPTAIN ASK note
  {
    printf 'id=test-ask-004\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf -- '--\n'
    printf 'Test when backlog missing\n'
  } >"$INBOX/test-ask-004.note"

  # Run check - should report unreconciled
  output=$("$SCRIPT_DIR/fm-ask-ledger-check.sh" check)
  [ -n "$output" ]
  [[ "$output" == *"test-ask-004"* ]]
}

@test "multiple unreconciled asks" {
  local SCRIPT_DIR INBOX
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
  INBOX="$TEST_STATE/inbox"

  # Create multiple CAPTAIN ASK notes
  {
    printf 'id=ask-a\n'
    printf 'at=2026-09-28T10:00:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf -- '--\n'
    printf 'First ask\n'
  } >"$INBOX/ask-a.note"

  {
    printf 'id=ask-b\n'
    printf 'at=2026-09-28T10:01:00Z\n'
    printf 'source=CAPTAIN ASK\n'
    printf 'announce_marker=1\n'
    printf -- '--\n'
    printf 'Second ask\n'
  } >"$INBOX/ask-b.note"

  # Run check - should report both
  output=$("$SCRIPT_DIR/fm-ask-ledger-check.sh" check)
  [ -n "$output" ]
  [[ "$output" == *"ask-a"* ]]
  [[ "$output" == *"ask-b"* ]]
}
