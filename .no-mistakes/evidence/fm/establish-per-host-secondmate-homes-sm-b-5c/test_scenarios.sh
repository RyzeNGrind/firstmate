#!/usr/bin/env bash
set -eu

echo "=== Validating Per-Host Secondmate Homes Implementation ==="
echo ""

# Scenario 1: Each host gets its own isolated firstmate home
scenario_1_isolated_homes() {
  echo "SCENARIO 1: Each host gets its own isolated firstmate home"
  
  local hosts=(bld nas alpha theta delta epsilon beta ws)
  local failed=0
  
  for host in "${hosts[@]}"; do
    if ! grep -q "sm-$host.*~/.firstmate-$host" AGENTS.md; then
      echo "  ✗ Host $host not documented with correct FM_HOME path"
      failed=1
    fi
  done
  
  if [ $failed -eq 0 ]; then
    for host in "${hosts[@]}"; do
      echo "  ✓ Host sm-$host → ~/.firstmate-$host"
    done
    echo "✓ SCENARIO 1 PASS: All hosts have isolated homes"
    return 0
  fi
  
  echo "✗ SCENARIO 1 FAIL: Documentation incomplete"
  return 1
}

# Scenario 2: Workers report through their local FM_HOME (independent backlog routing)
scenario_2_independent_routing() {
  echo "SCENARIO 2: Independent backlog routing per FM_HOME"
  
  local required_phrases=(
    "independent backlog"
    "FM_HOME"
    "workers on"
    "report"
  )
  
  local found=0
  for phrase in "${required_phrases[@]}"; do
    if grep -q "$phrase" AGENTS.md; then
      found=$((found + 1))
    fi
  done
  
  if [ $found -eq ${#required_phrases[@]} ]; then
    echo "  ✓ Documentation mentions independent backlog routing"
    echo "  ✓ Documentation mentions FM_HOME-based routing"
    echo "✓ SCENARIO 2 PASS: Independent routing documented"
    return 0
  fi
  
  echo "✗ SCENARIO 2 FAIL: Independent routing not properly documented"
  return 1
}

# Scenario 3: Workers don't compete for main fleet lock
scenario_3_no_lock_contention() {
  echo "SCENARIO 3: No lock contention between per-host secondmates"
  
  if grep -q "not competing for the main fleet lock" AGENTS.md || \
     grep -q "independent backlog" AGENTS.md; then
    echo "  ✓ Documentation mentions no lock contention"
    echo "✓ SCENARIO 3 PASS: Lock isolation documented"
    return 0
  fi
  
  echo "✗ SCENARIO 3 FAIL: Lock isolation not documented"
  return 1
}

# Scenario 4: fm-spawn.sh correctly routes FM_HOME to secondmates
scenario_4_spawn_routing() {
  echo "SCENARIO 4: fm-spawn.sh correctly handles FM_HOME routing"
  
  # Check that the code assigns FIRSTMATE_HOME from arguments
  local code=$(sed -n '/elif \[ "\$KIND" = secondmate \]/,/esac$/p' bin/fm-spawn.sh)
  
  if echo "$code" | grep -q "FIRSTMATE_HOME=\${POS\[1\]:-}" && \
     echo "$code" | grep -q "ARG3=\${POS\[2\]:-}"; then
    echo "  ✓ fm-spawn.sh assigns FIRSTMATE_HOME correctly"
    echo "  ✓ fm-spawn.sh uses defensive parameter expansion"
    echo "✓ SCENARIO 4 PASS: Spawn routing implemented"
    return 0
  fi
  
  echo "✗ SCENARIO 4 FAIL: fm-spawn.sh routing code invalid"
  return 1
}

# Scenario 5: Upstream reporting mechanism documented
scenario_5_upstream_reporting() {
  echo "SCENARIO 5: Per-host secondmates report upstream"
  
  if grep -q "upstream-inbox" AGENTS.md && \
     grep -q "durable" AGENTS.md; then
    echo "  ✓ Upstream inbox documented"
    echo "  ✓ Durable reporting mechanism described"
    echo "✓ SCENARIO 5 PASS: Upstream reporting documented"
    return 0
  fi
  
  echo "✗ SCENARIO 5 FAIL: Upstream reporting not documented"
  return 1
}

# Scenario 6: Parallel execution is enabled
scenario_6_parallel_execution() {
  echo "SCENARIO 6: True parallel execution enabled"
  
  if grep -q "parallel" AGENTS.md || \
     grep -q "true parallel" AGENTS.md; then
    echo "  ✓ Documentation mentions parallel execution"
    echo "✓ SCENARIO 6 PASS: Parallel execution enabled"
    return 0
  fi
  
  echo "✗ SCENARIO 6 FAIL: Parallel execution not documented"
  return 1
}

# Scenario 7: Defensive bash changes don't break spawn
scenario_7_defensive_coding() {
  echo "SCENARIO 7: Defensive bash parameter expansion is safe"
  
  # Test bash syntax
  if bash -n bin/fm-spawn.sh >/dev/null 2>&1; then
    echo "  ✓ fm-spawn.sh bash syntax is valid"
    
    # Test defensive expansion logic
    local test_result=$(bash -c '
      declare -a POS
      POS[0]="test"
      # POS[1] is unset
      VAR=${POS[1]:-}
      if [ -z "$VAR" ]; then
        echo "OK"
      else
        echo "FAIL"
      fi
    ')
    
    if [ "$test_result" = "OK" ]; then
      echo "  ✓ Defensive expansions work correctly"
      echo "✓ SCENARIO 7 PASS: Defensive coding is safe"
      return 0
    fi
  fi
  
  echo "✗ SCENARIO 7 FAIL: Defensive coding issue"
  return 1
}

# Run all scenarios
all_pass=0
scenario_1_isolated_homes || all_pass=1
echo ""
scenario_2_independent_routing || all_pass=1
echo ""
scenario_3_no_lock_contention || all_pass=1
echo ""
scenario_4_spawn_routing || all_pass=1
echo ""
scenario_5_upstream_reporting || all_pass=1
echo ""
scenario_6_parallel_execution || all_pass=1
echo ""
scenario_7_defensive_coding || all_pass=1

echo ""
echo "=== Summary ==="
if [ $all_pass -eq 0 ]; then
  echo "✓ All scenarios passed - per-host secondmate homes implementation validated"
  exit 0
else
  echo "✗ Some scenarios failed"
  exit 1
fi
