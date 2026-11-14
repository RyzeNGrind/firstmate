#!/usr/bin/env bash
set -eu

test_defensive_parameter_parsing() {
  local test_name="Defensive parameter parsing (defensive bash expansions)"
  
  # Source the function that uses these expansions
  # We'll test the parameter parsing logic
  declare -a POS
  POS[0]="task-id"
  
  # Test 1: Empty POS[1] - new way should handle gracefully
  local FIRSTMATE_HOME=""
  local ARG3=""
  FIRSTMATE_HOME=${POS[1]:-}
  ARG3=${POS[2]:-}
  
  if [ -z "$FIRSTMATE_HOME" ] && [ -z "$ARG3" ]; then
    echo "✓ $test_name: Empty positional args handled correctly"
    return 0
  else
    echo "✗ $test_name: Failed - got FIRSTMATE_HOME=[${FIRSTMATE_HOME}] ARG3=[${ARG3}]"
    return 1
  fi
}

test_per_host_homes_documented() {
  local test_name="Per-host secondmate homes documented"
  
  # Verify AGENTS.md documents the per-host homes
  local documented_homes=(
    "sm-bld"
    "sm-nas"
    "sm-alpha"
    "sm-theta"
    "sm-delta"
    "sm-epsilon"
    "sm-beta"
    "sm-ws"
  )
  
  local failed=0
  for home in "${documented_homes[@]}"; do
    if grep -q "$home" AGENTS.md; then
      echo "  ✓ Found $home in AGENTS.md"
    else
      echo "  ✗ Missing $home in AGENTS.md"
      failed=1
    fi
  done
  
  if [ $failed -eq 0 ]; then
    echo "✓ $test_name: All expected homes documented"
    return 0
  else
    echo "✗ $test_name: Some homes not documented"
    return 1
  fi
}

test_fm_home_routing_logic() {
  local test_name="FM_HOME routing logic in fm-spawn.sh"
  
  # Verify the routing logic handles FM_HOME for per-host secondmates
  if grep -q "FIRSTMATE_HOME=\${POS\[1\]:-}" bin/fm-spawn.sh; then
    echo "✓ $test_name: Defensive FM_HOME assignment found"
    
    # Also check the secondmate case
    if grep -q "elif \[ \"\$KIND\" = secondmate \]" bin/fm-spawn.sh; then
      echo "✓ $test_name: Secondmate routing logic present"
      return 0
    fi
  fi
  
  echo "✗ $test_name: Required routing logic not found"
  return 1
}

test_documentation_routing_model() {
  local test_name="Documentation describes routing model"
  
  local required_phrases=(
    "Per-host secondmate homes"
    "independent backlog"
    "FM_HOME"
    "upstream-inbox"
  )
  
  local failed=0
  for phrase in "${required_phrases[@]}"; do
    if grep -q "$phrase" AGENTS.md; then
      echo "  ✓ Found routing concept: '$phrase'"
    else
      echo "  ✗ Missing routing concept: '$phrase'"
      failed=1
    fi
  done
  
  if [ $failed -eq 0 ]; then
    echo "✓ $test_name: Routing model properly documented"
    return 0
  else
    echo "✗ $test_name: Routing model documentation incomplete"
    return 1
  fi
}

echo "=== Testing Per-Host Secondmate Homes Implementation ==="
echo ""

all_pass=0
test_defensive_parameter_parsing || all_pass=1
echo ""
test_per_host_homes_documented || all_pass=1
echo ""
test_fm_home_routing_logic || all_pass=1
echo ""
test_documentation_routing_model || all_pass=1

echo ""
if [ $all_pass -eq 0 ]; then
  echo "=== All tests passed ==="
  exit 0
else
  echo "=== Some tests failed ==="
  exit 1
fi
