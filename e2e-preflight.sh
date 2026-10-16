#!/run/current-system/sw/bin/bash
# nv-m3 Phase 1 E2E Infrastructure Preflight Check
# Validates all required test infrastructure components before execution

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNING=0

# Log functions
log_pass() {
  echo -e "${GREEN}✓${NC} $1"
  ((CHECKS_PASSED++))
}

log_fail() {
  echo -e "${RED}✗${NC} $1"
  ((CHECKS_FAILED++))
}

log_warn() {
  echo -e "${YELLOW}⚠${NC} $1"
  ((CHECKS_WARNING++))
}

log_info() {
  echo -e "${YELLOW}ℹ${NC} $1"
}

echo "=========================================="
echo "nv-m3 Phase 1 E2E Infrastructure Checks"
echo "=========================================="
echo ""

# Check 1: SQL Fixtures file
echo "Checking test fixtures..."
if [ -f "__tests__/fixtures/e2e-test-data.sql" ]; then
  log_pass "e2e-test-data.sql exists"
  if grep -q "INSERT INTO users" "__tests__/fixtures/e2e-test-data.sql" 2>/dev/null; then
    log_pass "e2e-test-data.sql contains user fixtures"
  else
    log_warn "e2e-test-data.sql missing user fixtures"
  fi
  if grep -q "INSERT INTO bookings" "__tests__/fixtures/e2e-test-data.sql" 2>/dev/null; then
    log_pass "e2e-test-data.sql contains booking fixtures"
  else
    log_warn "e2e-test-data.sql missing booking fixtures"
  fi
  if grep -q "INSERT INTO payment_intents" "__tests__/fixtures/e2e-test-data.sql" 2>/dev/null; then
    log_pass "e2e-test-data.sql contains payment intent fixtures"
  else
    log_warn "e2e-test-data.sql missing payment intent fixtures"
  fi
else
  log_fail "e2e-test-data.sql not found"
fi
echo ""

# Check 2: TypeScript helpers
echo "Checking TypeScript helpers..."
if [ -f "__tests__/helpers/e2e-helpers.ts" ]; then
  log_pass "e2e-helpers.ts exists"

  # Check for required exports
  if grep -q "export async function initTestDb" "__tests__/helpers/e2e-helpers.ts" 2>/dev/null; then
    log_pass "initTestDb function exported"
  else
    log_fail "initTestDb function not found"
  fi

  if grep -q "export async function loadTestFixtures" "__tests__/helpers/e2e-helpers.ts" 2>/dev/null; then
    log_pass "loadTestFixtures function exported"
  else
    log_fail "loadTestFixtures function not found"
  fi

  if grep -q "export async function createTestPaymentIntent" "__tests__/helpers/e2e-helpers.ts" 2>/dev/null; then
    log_pass "createTestPaymentIntent function exported"
  else
    log_fail "createTestPaymentIntent function not found"
  fi

  if grep -q "export async function simulateWebhookEvent" "__tests__/helpers/e2e-helpers.ts" 2>/dev/null; then
    log_pass "simulateWebhookEvent function exported"
  else
    log_fail "simulateWebhookEvent function not found"
  fi

  if grep -q "export async function cleanupTestData" "__tests__/helpers/e2e-helpers.ts" 2>/dev/null; then
    log_pass "cleanupTestData function exported"
  else
    log_fail "cleanupTestData function not found"
  fi
else
  log_fail "e2e-helpers.ts not found"
fi
echo ""

# Check 3: Test matrix documentation
echo "Checking test matrix documentation..."
if [ -f "__tests__/m3-booking-square-checkout-e2e.md" ]; then
  log_pass "m3-booking-square-checkout-e2e.md exists"

  CHECKOUT_SCENARIOS=$(grep -c "^### Scenario" "__tests__/m3-booking-square-checkout-e2e.md" 2>/dev/null || true)
  if [ "$CHECKOUT_SCENARIOS" -eq 5 ]; then
    log_pass "All 5 checkout scenarios documented"
  else
    log_warn "Expected 5 checkout scenarios, found $CHECKOUT_SCENARIOS"
  fi
else
  log_fail "m3-booking-square-checkout-e2e.md not found"
fi
echo ""

# Check 4: Webhook test matrix
echo "Checking webhook test matrix..."
if [ -f "__tests__/m3-booking-square-webhook-e2e.md" ]; then
  log_pass "m3-booking-square-webhook-e2e.md exists"

  WEBHOOK_SCENARIOS=$(grep -c "^### Scenario" "__tests__/m3-booking-square-webhook-e2e.md" 2>/dev/null || true)
  if [ "$WEBHOOK_SCENARIOS" -eq 6 ]; then
    log_pass "All 6 webhook scenarios documented"
  else
    log_warn "Expected 6 webhook scenarios, found $WEBHOOK_SCENARIOS"
  fi
else
  log_fail "m3-booking-square-webhook-e2e.md not found"
fi
echo ""

# Check 5: Required environment setup
echo "Checking environment prerequisites..."
if command -v node &> /dev/null; then
  NODE_VERSION=$(node --version)
  log_pass "Node.js installed: $NODE_VERSION"
else
  log_warn "Node.js not installed (required for running tests)"
fi

if command -v npm &> /dev/null; then
  NPM_VERSION=$(npm --version)
  log_pass "npm installed: $NPM_VERSION"
else
  log_warn "npm not installed (required for installing dependencies)"
fi

if command -v tsc &> /dev/null; then
  TS_VERSION=$(tsc --version)
  log_pass "TypeScript compiler installed: $TS_VERSION"
else
  log_warn "TypeScript compiler not found (run: npm install -g typescript)"
fi

if command -v psql &> /dev/null; then
  log_pass "PostgreSQL client installed"
else
  log_warn "PostgreSQL client not installed (required for database tests)"
fi
echo ""

# Check 6: TypeScript compilation (if tsc available)
echo "Checking TypeScript compilation..."
if command -v tsc &> /dev/null; then
  if tsc --noEmit "__tests__/helpers/e2e-helpers.ts" 2>/dev/null; then
    log_pass "e2e-helpers.ts compiles without errors"
  else
    log_fail "e2e-helpers.ts has TypeScript errors"
    echo "  Run: tsc __tests__/helpers/e2e-helpers.ts --noEmit for details"
  fi
else
  log_warn "TypeScript compiler not installed - skipping compilation check"
  log_info "Install with: npm install -g typescript"
fi
echo ""

# Summary
echo "=========================================="
echo "Preflight Check Summary"
echo "=========================================="
echo -e "Passed: ${GREEN}$CHECKS_PASSED${NC}"
echo -e "Failed: ${RED}$CHECKS_FAILED${NC}"
echo -e "Warnings: ${YELLOW}$CHECKS_WARNING${NC}"
echo ""

if [ $CHECKS_FAILED -eq 0 ]; then
  echo -e "${GREEN}✓ E2E Infrastructure Ready${NC}"
  exit 0
else
  echo -e "${RED}✗ E2E Infrastructure Issues Found${NC}"
  exit 1
fi
