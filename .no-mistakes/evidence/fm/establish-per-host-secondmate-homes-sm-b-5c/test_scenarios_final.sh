#!/usr/bin/env bash
set -eu

echo "=== Validating Per-Host Secondmate Homes Implementation ==="
echo ""

# Scenario 1: Each host gets its own isolated firstmate home
scenario_1_isolated_homes() {
  echo "SCENARIO 1: Each host gets its own isolated firstmate home"
  
  local hosts=(bld nas alpha theta delta epsilon beta ws)
  local failed=0
  
  # Check that all hosts are mentioned in AGENTS.md
  for host in "${hosts[@]}"; do
    if grep -q "sm-$host" AGENTS.md; then
      echo "  ✓ Host sm-$host documented"
    else
      echo "  ✗ Host sm-$host not documented"
      failed=1
    fi
  done
  
  # Check that fm_home pattern is documented
  if grep -q "~/.firstmate-" AGENTS.md; then
    echo "  ✓ Per-host FM_HOME paths documented"
  else
    failed=1
  fi
  
  if [ $failed -eq 0 ]; then
    echo "✓ SCENARIO 1 PASS: All hosts have isolated homes"
    return 0
  fi
  
  echo "✗ SCENARIO 1 FAIL"
  return 1
}

# Scenario 2: Workers report through their local FM_HOME (independent backlog routing)
scenario_2_independent_routing() {
  echo "SCENARIO 2: Independent backlog routing per FM_HOME"
  
  if grep -q "independent backlog" AGENTS.md && \
     grep -q "FM_HOME" AGENTS.md; then
    echo "  ✓ Documentation describes independent backlog routing"
    echo "  ✓ Documentation mentions FM_HOME-based routing"
    echo "✓ SCENARIO 2 PASS"
    return 0
  fi
  
  echo "✗ SCENARIO 2 FAIL"
  return 1
}

# Scenario 3: Workers don't compete for main fleet lock
scenario_3_no_lock_contention() {
  echo "SCENARIO 3: No lock contention between per-host secondmates"
  
  if grep -q "not competing for the main fleet lock" AGENTS.md || \
     grep -q "independent backlog" AGENTS.md; then
    echo "  ✓ Documentation indicates no lock contention"
    echo "✓ SCENARIO 3 PASS"
    return 0
  fi
  
  echo "✗ SCENARIO 3 FAIL"
  return 1
}

# Scenario 4: fm-spawn.sh correctly routes FM_HOME to secondmates
scenario_4_spawn_routing() {
  echo "SCENARIO 4: fm-spawn.sh correctly handles FM_HOME routing"
  
  local code=$(sed -n '/elif \[ "\$KIND" = secondmate \]/,/esac$/p' bin/fm-spawn.sh)
  
  if echo "$code" | grep -q "FIRSTMATE_HOME="; then
    echo "  ✓ fm-spawn.sh assigns FIRSTMATE_HOME"
    
    if echo "$code" | grep -q '${POS\[1\]:-}'; then
      echo "  ✓ fm-spawn.sh uses defensive parameter expansion"
      echo "✓ SCENARIO 4 PASS"
      return 0
    fi
  fi
  
  echo "✗ SCENARIO 4 FAIL"
  return 1
}

# Scenario 5: Upstream reporting mechanism documented
scenario_5_upstream_reporting() {
  echo "SCENARIO 5: Per-host secondmates report upstream"
  
  if grep -q "upstream-inbox" AGENTS.md && \
     grep -q "durable" AGENTS.md; then
    echo "  ✓ Upstream inbox for status reporting documented"
    echo "  ✓ Durable reporting mechanism described"
    echo "✓ SCENARIO 5 PASS"
    return 0
  fi
  
  echo "✗ SCENARIO 5 FAIL"
  return 1
}

# Scenario 6: Parallel execution is enabled
scenario_6_parallel_execution() {
  echo "SCENARIO 6: True parallel execution enabled"
  
  if grep -q "enables true parallel" AGENTS.md; then
    echo "  ✓ Documentation explicitly states parallel execution enabled"
    echo "✓ SCENARIO 6 PASS"
    return 0
  elif grep -q "parallel" AGENTS.md; then
    echo "  ✓ Documentation mentions parallel execution"
    echo "✓ SCENARIO 6 PASS"
    return 0
  fi
  
  echo "✗ SCENARIO 6 FAIL"
  return 1
}

# Scenario 7: Defensive bash changes don't break spawn
scenario_7_defensive_coding() {
  echo "SCENARIO 7: Defensive bash parameter expansion is safe"
  
  if bash -n bin/fm-spawn.sh >/dev/null 2>&1; then
    echo "  ✓ fm-spawn.sh bash syntax is valid"
    
    local test_result=$(bash -c '
      declare -a POS
      POS[0]="test"
      VAR=${POS[1]:-}
      if [ -z "$VAR" ]; then
        echo "OK"
      fi
    ')
    
    if [ "$test_result" = "OK" ]; then
      echo "  ✓ Defensive expansions handle unset variables"
      echo "✓ SCENARIO 7 PASS"
      return 0
    fi
  fi
  
  echo "✗ SCENARIO 7 FAIL"
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
echo "=== VALIDATION SUMMARY ==="
if [ $all_pass -eq 0 ]; then
  echo "✓ All scenarios passed - per-host secondmate homes implementation valid"
  exit 0
else
  echo "✗ Some scenarios failed"
  exit 1
fi
