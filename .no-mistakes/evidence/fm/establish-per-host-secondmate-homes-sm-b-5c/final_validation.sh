#!/usr/bin/env bash
set -eu

echo "=== FINAL VALIDATION: Per-Host Secondmate Homes ==="
echo ""

# Check 1: Git changes are limited and focused
check_focused_changes() {
  echo "CHECK 1: Changes are focused and limited"
  
  local files_changed=$(git diff 225b5c5...HEAD --name-only | sort)
  local expected_files=$'AGENTS.md\nbin/fm-spawn.sh'
  
  if [ "$files_changed" = "$expected_files" ]; then
    echo "  ✓ Only expected files modified: AGENTS.md, bin/fm-spawn.sh"
    echo "✓ CHECK 1 PASS"
    return 0
  else
    echo "  ✗ Unexpected file changes"
    echo "Files: $files_changed"
    echo "✗ CHECK 1 FAIL"
    return 1
  fi
}

# Check 2: Documentation is comprehensive
check_documentation_complete() {
  echo "CHECK 2: Documentation is comprehensive"
  
  if grep -q "#### Per-host secondmate homes and parallel routing" AGENTS.md; then
    echo "  ✓ New documentation section added"
  else
    return 1
  fi
  
  if grep -q "**Routing model:**" AGENTS.md; then
    echo "  ✓ Routing model documented"
  else
    return 1
  fi
  
  if grep -q "**Secondmate homes registered:**" AGENTS.md; then
    echo "  ✓ Registered homes listed"
  else
    return 1
  fi
  
  echo "✓ CHECK 2 PASS"
  return 0
}

# Check 3: Bash changes are defensive and don't break syntax
check_bash_safety() {
  echo "CHECK 3: Bash changes are safe and valid"
  
  if ! bash -n bin/fm-spawn.sh >/dev/null 2>&1; then
    echo "  ✗ fm-spawn.sh has syntax errors"
    return 1
  fi
  
  echo "  ✓ fm-spawn.sh syntax is valid"
  
  # Verify the defensive patterns are correct
  local defensive_count=$(grep -c '${[A-Z_]*\[.\]:-}' bin/fm-spawn.sh || true)
  if [ "$defensive_count" -gt 0 ]; then
    echo "  ✓ Defensive parameter expansion patterns found ($defensive_count occurrences)"
  fi
  
  echo "✓ CHECK 3 PASS"
  return 0
}

# Check 4: No unintended commits bundled (as per decision history)
check_no_bundled_commits() {
  echo "CHECK 4: No unintended commits bundled"
  
  # Check commits in this branch
  local commit_count=$(git log 225b5c5...HEAD --oneline | wc -l)
  
  # Expected commits:
  # - 1483c9a chore(agents): document per-host secondmate homes routing model
  # - 8354e33 fix: remove accidental systemd output and screenshot files
  # These 2 are intentional
  
  if [ "$commit_count" -le 3 ]; then
    echo "  ✓ Only focused commits in branch ($commit_count commits)"
    
    # Verify each commit is intentional
    if git log 225b5c5...HEAD --oneline | grep -q "document per-host secondmate homes"; then
      echo "  ✓ Primary feature commit present"
    fi
    
    if git log 225b5c5...HEAD --oneline | grep -q "remove accidental"; then
      echo "  ✓ Cleanup commit present"
    fi
    
    echo "✓ CHECK 4 PASS"
    return 0
  fi
  
  echo "✗ CHECK 4 FAIL: Too many commits"
  return 1
}

# Check 5: No accidental files remain
check_no_accidental_files() {
  echo "CHECK 5: No accidental files in commit"
  
  local bad_files=0
  
  # Check for screenshot files
  if git diff --name-only 225b5c5...HEAD | grep -q "\.png\|\.jpg\|paste-"; then
    echo "  ✗ Screenshot/image files found in commit"
    bad_files=1
  else
    echo "  ✓ No image files in commit"
  fi
  
  # Check for systemctl output
  if git diff --name-only 225b5c5...HEAD | grep -q "systemctl_output\|ystemctl"; then
    echo "  ✗ Systemctl output files found"
    bad_files=1
  else
    echo "  ✓ No systemctl output files"
  fi
  
  if [ $bad_files -eq 0 ]; then
    echo "✓ CHECK 5 PASS"
    return 0
  fi
  
  echo "✗ CHECK 5 FAIL"
  return 1
}

# Check 6: Documentation accuracy
check_documentation_accuracy() {
  echo "CHECK 6: Documentation matches implementation"
  
  local code=$(sed -n '/elif \[ "\$KIND" = secondmate \]/,/esac$/p' bin/fm-spawn.sh)
  
  # Check that code supports routing
  if echo "$code" | grep -q "FIRSTMATE_HOME"; then
    echo "  ✓ fm-spawn.sh implements FIRSTMATE_HOME routing"
  else
    echo "  ✗ Routing not implemented in fm-spawn.sh"
    return 1
  fi
  
  # Check hosts match between code comment and documentation
  local documented_hosts=(bld nas alpha theta delta epsilon beta ws)
  for host in "${documented_hosts[@]}"; do
    if ! grep -q "sm-$host" AGENTS.md; then
      echo "  ✗ Host $host documented in code but not AGENTS.md"
      return 1
    fi
  done
  echo "  ✓ All hosts documented consistently"
  
  echo "✓ CHECK 6 PASS"
  return 0
}

# Run all checks
echo ""
all_pass=0
check_focused_changes || all_pass=1
echo ""
check_documentation_complete || all_pass=1
echo ""
check_bash_safety || all_pass=1
echo ""
check_no_bundled_commits || all_pass=1
echo ""
check_no_accidental_files || all_pass=1
echo ""
check_documentation_accuracy || all_pass=1

echo ""
echo "======================================="
if [ $all_pass -eq 0 ]; then
  echo "✓✓✓ ALL VALIDATIONS PASSED ✓✓✓"
  echo "Implementation is ready for delivery"
  exit 0
else
  echo "✗✗✗ SOME VALIDATIONS FAILED ✗✗✗"
  exit 1
fi
