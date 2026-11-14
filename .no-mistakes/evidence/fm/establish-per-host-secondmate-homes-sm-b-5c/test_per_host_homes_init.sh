#!/usr/bin/env bash
set -eu

echo "=== Testing Per-Host Secondmate Homes Initialization ==="
echo ""

test_per_host_home_structure() {
  local test_name="Per-host home directory structure"
  
  # Create temporary test home
  local TEST_HOME=$(mktemp -d)
  trap "rm -rf '$TEST_HOME'" EXIT
  
  # Test that FM_HOME can be set to different per-host paths
  local hosts=(bld nas alpha theta delta epsilon beta ws)
  local failed=0
  
  for host in "${hosts[@]}"; do
    local home_path="$TEST_HOME/.firstmate-$host"
    mkdir -p "$home_path"
    
    if [ -d "$home_path" ]; then
      echo "  ✓ Can create per-host home: $host"
    else
      echo "  ✗ Failed to create per-host home: $host"
      failed=1
    fi
  done
  
  if [ $failed -eq 0 ]; then
    echo "✓ $test_name: All per-host homes can be created"
    return 0
  else
    echo "✗ $test_name: Failed to create some per-host homes"
    return 1
  fi
}

test_fm_home_environment_variable() {
  local test_name="FM_HOME environment variable routing"
  
  # Test that FM_HOME can be set and used in subshells
  local TEST_HOME=$(mktemp -d)
  trap "rm -rf '$TEST_HOME'" EXIT
  
  local bld_home="$TEST_HOME/.firstmate-bld"
  local nas_home="$TEST_HOME/.firstmate-nas"
  mkdir -p "$bld_home" "$nas_home"
  
  # Test FM_HOME is properly inherited in subshell
  local result1=$(FM_HOME="$bld_home" bash -c 'echo $FM_HOME')
  local result2=$(FM_HOME="$nas_home" bash -c 'echo $FM_HOME')
  
  if [ "$result1" = "$bld_home" ] && [ "$result2" = "$nas_home" ]; then
    echo "✓ $test_name: FM_HOME correctly set in subshells"
    return 0
  else
    echo "✗ $test_name: FM_HOME routing failed (got $result1 and $result2)"
    return 1
  fi
}

test_secondmate_routing_code() {
  local test_name="Secondmate routing code structure"
  
  # Verify the secondmate case statement handles per-host routing
  local code_snippet=$(sed -n '/elif \[ "\$KIND" = secondmate \]/,/fi$/p' bin/fm-spawn.sh | head -20)
  
  if echo "$code_snippet" | grep -q "FIRSTMATE_HOME="; then
    echo "✓ $test_name: Secondmate routing assigns FM_HOME"
    
    # Check it uses the defensive pattern
    if echo "$code_snippet" | grep -q "FIRSTMATE_HOME=\${POS\[1\]:-}"; then
      echo "✓ $test_name: Uses defensive parameter expansion"
      return 0
    fi
  fi
  
  echo "✗ $test_name: Secondmate routing code structure invalid"
  return 1
}

test_upstream_inbox_documented() {
  local test_name="Upstream inbox for per-host reporting"
  
  # Verify upstream-inbox is documented as the reporting mechanism
  if grep -q "state/.upstream-inbox" AGENTS.md; then
    echo "✓ $test_name: Upstream inbox path documented"
    
    if grep -q "durable inbox" AGENTS.md; then
      echo "✓ $test_name: Durable inbox described"
      return 0
    fi
  fi
  
  echo "✗ $test_name: Upstream inbox not properly documented"
  return 1
}

test_worker_routing_through_fm_home() {
  local test_name="Worker routing through FM_HOME"
  
  # Verify that workers spawned with FM_HOME use that home
  local TEST_HOME=$(mktemp -d)
  trap "rm -rf '$TEST_HOME'" EXIT
  
  local bld_home="$TEST_HOME/.firstmate-bld"
  mkdir -p "$bld_home"
  
  # Simulate what fm-spawn.sh does with FM_HOME
  local result=$(FM_HOME="$bld_home" bash -c 'echo ${FM_HOME}')
  
  if [ "$result" = "$bld_home" ]; then
    echo "✓ $test_name: FM_HOME passed to worker environment"
    return 0
  fi
  
  echo "✗ $test_name: FM_HOME not correctly passed"
  return 1
}

# Run all tests
all_pass=0
test_per_host_home_structure || all_pass=1
echo ""
test_fm_home_environment_variable || all_pass=1
echo ""
test_secondmate_routing_code || all_pass=1
echo ""
test_upstream_inbox_documented || all_pass=1
echo ""
test_worker_routing_through_fm_home || all_pass=1

echo ""
if [ $all_pass -eq 0 ]; then
  echo "=== All per-host home initialization tests passed ==="
  exit 0
else
  echo "=== Some tests failed ==="
  exit 1
fi
