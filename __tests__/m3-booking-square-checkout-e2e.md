# nv-m3 Square Checkout E2E Test Matrix - Phase 1

## Overview
This document defines the 5 primary checkout flow scenarios for nv-m3 booking system integration with Square Payment API. These tests validate the end-to-end payment processing from booking confirmation through Square receipt.

## Test Environment
- Database: PostgreSQL (test instance)
- Square API: Uses test/sandbox credentials
- Test User: Non-interactive test fixture data
- No credentials required for infrastructure validation

## Checkout Scenarios

### Scenario 1: Successful Payment Processing
**ID**: `checkout_001_success_flow`
**Status**: Ready for implementation
**Description**: User completes booking and successfully processes payment through Square

**Steps**:
1. User initiates checkout from booking confirmation
2. Square payment form loads with booking amount
3. User enters valid test card number
4. Payment is submitted to Square API
5. Square returns successful payment intent
6. Booking status updates to `confirmed`
7. Payment record created with `completed` status

**Expected Outcome**: 
- Payment intent `status` = `completed`
- Booking `status` = `confirmed`
- No error messages displayed

**Assertions**:
- `payment_intents.status` = `'completed'`
- `bookings.status` = `'confirmed'`
- Square `payment_id` stored in `payment_intents.square_request_id`

---

### Scenario 2: Declined Card Payment
**ID**: `checkout_002_declined_card`
**Status**: Ready for implementation
**Description**: User attempts payment with declined test card

**Steps**:
1. User completes booking and initiates checkout
2. User enters declined test card (4000002500001001)
3. Payment submitted to Square
4. Square returns decline response
5. Payment intent set to `failed`
6. User sees error message and can retry

**Expected Outcome**:
- Payment intent `status` = `failed`
- Booking remains in `pending` state
- Error message displayed to user
- Retry button enabled

**Assertions**:
- `payment_intents.status` = `'failed'`
- `bookings.status` = `'pending'`
- `payment_intents.square_request_id` contains Square decline reason

---

### Scenario 3: Expired Test Card
**ID**: `checkout_003_expired_card`
**Status**: Ready for implementation
**Description**: User attempts payment with expired test card

**Steps**:
1. User initiates checkout flow
2. User enters expired card (any card with past expiry)
3. Client-side validation catches expiry error
4. Square verification rejects card
5. Payment intent marked `failed`

**Expected Outcome**:
- Client displays "Card expired" error
- Payment intent not created (validation caught early)
- User can select different card

**Assertions**:
- No payment intent created
- Client validation error message shown
- User can retry with valid card

---

### Scenario 4: Timeout During Payment Processing
**ID**: `checkout_004_payment_timeout`
**Status**: Ready for implementation
**Description**: Network timeout occurs during Square payment submission

**Steps**:
1. User completes booking and initiates payment
2. Request sent to Square API
3. Network connection drops/timeout occurs
4. Client-side timeout handler triggered
5. Payment intent remains in `pending` state
6. User sees retry message

**Expected Outcome**:
- Payment intent `status` = `pending`
- No confirmation stored until retry completes
- User prompted to retry

**Assertions**:
- `payment_intents.status` = `'pending'`
- Booking still `'pending'`
- Retry handler enabled
- Idempotency key prevents duplicate charges on retry

---

### Scenario 5: Concurrent Checkout Attempts
**ID**: `checkout_005_concurrent_attempts`
**Status**: Ready for implementation
**Description**: User attempts to submit payment twice rapidly (e.g., double-click)

**Steps**:
1. User fills checkout form and clicks Pay
2. Before payment completes, user clicks Pay again
3. First request sent to Square
4. Second request should be blocked by UI state
5. Only one payment processed

**Expected Outcome**:
- Second request blocked by UI/state management
- Single payment intent created
- No duplicate charges

**Assertions**:
- Only one `payment_intent` record created
- Button disabled during processing
- User sees loading state on first click
- Single Square charge created

---

## Checkout Flow Assertions Checklist

- [ ] All scenarios have unique scenario IDs
- [ ] Each scenario has clear step-by-step flow
- [ ] Expected outcomes defined for each scenario
- [ ] Database assertions use exact column names
- [ ] Test card numbers match Square's test suite
- [ ] Error handling paths documented
- [ ] Edge cases (timeout, duplicate, expired) covered
- [ ] No real Square credentials required for setup

## Next Steps
- Implement automated tests for each scenario
- Configure Square test/sandbox API keys
- Set up test database seeding from `e2e-test-data.sql`
- Run preflight checks with `e2e-preflight.sh`
