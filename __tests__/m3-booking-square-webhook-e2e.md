# nv-m3 Square Webhook E2E Test Matrix - Phase 1

## Overview
This document defines the 6 primary webhook event scenarios for nv-m3 Square integration. These tests validate that webhook events from Square are correctly received, verified, and processed by the booking system.

## Test Environment
- Webhook Receiver: Local test server or webhook.site endpoint
- Square Sandbox: Test webhook endpoints
- Test Events: Simulated Square webhook payloads
- No credentials required for infrastructure validation

## Webhook Scenarios

### Scenario 1: Payment Created Webhook
**ID**: `webhook_001_payment_created`
**Status**: Ready for implementation
**Description**: Square sends `payment.created` webhook when a new payment is initiated

**Webhook Payload**:
```json
{
  "type": "payment.created",
  "data": {
    "object": {
      "payment": {
        "id": "sqpay_test_001",
        "amount_money": { "amount": 9999, "currency": "USD" },
        "status": "COMPLETED",
        "receipt_number": "123456",
        "created_at": "2026-10-16T10:00:00Z"
      }
    }
  }
}
```

**Processing Steps**:
1. Webhook endpoint receives POST request
2. Verify webhook signature using Square webhook key
3. Extract payment ID from webhook data
4. Match payment to booking using `square_request_id`
5. Update `payment_intents.status` to `completed`
6. Update `bookings.status` to `confirmed`

**Expected Outcome**:
- Webhook processed within 5 seconds
- Payment intent updated to `completed`
- Booking confirmed
- Webhook marked as `processed` = `true`

**Assertions**:
- `webhook_events.processed` = `true`
- `payment_intents.status` = `'completed'`
- `payment_intents.square_request_id` matches webhook payment ID
- `bookings.status` = `'confirmed'`

---

### Scenario 2: Payment Completed Webhook
**ID**: `webhook_002_payment_completed`
**Status**: Ready for implementation
**Description**: Square confirms payment completion with additional settlement details

**Webhook Payload**:
```json
{
  "type": "payment.updated",
  "data": {
    "object": {
      "payment": {
        "id": "sqpay_test_002",
        "status": "COMPLETED",
        "receipt_url": "https://squareup.com/receipt/...",
        "receipt_number": "789012"
      }
    }
  }
}
```

**Processing Steps**:
1. Receive `payment.updated` webhook
2. Verify webhook authenticity
3. Check if payment status changed to `COMPLETED`
4. Store receipt URL for customer communication
5. Mark booking as `confirmed` if not already

**Expected Outcome**:
- Receipt URL stored in booking or payment record
- Confirmation email triggered
- Webhook processed successfully

**Assertions**:
- `webhook_events.type` = `'payment.updated'`
- `webhook_events.processed` = `true`
- Payment receipt URL stored
- No duplicate processing of same webhook

---

### Scenario 3: Payment Refunded Webhook
**ID**: `webhook_003_payment_refunded`
**Status**: Ready for implementation
**Description**: Square notifies of refund when user cancels booking

**Webhook Payload**:
```json
{
  "type": "payment.updated",
  "data": {
    "object": {
      "payment": {
        "id": "sqpay_test_003",
        "status": "COMPLETED",
        "refunds": [
          {
            "id": "refund_001",
            "amount_money": { "amount": 9999, "currency": "USD" },
            "status": "COMPLETED",
            "created_at": "2026-10-16T11:00:00Z"
          }
        ]
      }
    }
  }
}
```

**Processing Steps**:
1. Receive webhook with refund in payment object
2. Verify refund was processed by Square
3. Update payment status to `refunded`
4. Update booking status to `cancelled`
5. Log refund amount and timestamp

**Expected Outcome**:
- Booking status changed to `cancelled`
- Refund amount recorded
- Customer notified of refund

**Assertions**:
- `payment_intents.status` = `'refunded'`
- `bookings.status` = `'cancelled'`
- Refund amount matches original charge

---

### Scenario 4: Payment Failed Webhook
**ID**: `webhook_004_payment_failed`
**Status**: Ready for implementation
**Description**: Square notifies of failed payment (e.g., insufficient funds)

**Webhook Payload**:
```json
{
  "type": "payment.updated",
  "data": {
    "object": {
      "payment": {
        "id": "sqpay_test_004",
        "status": "FAILED",
        "failure_code": "INSUFFICIENT_FUNDS",
        "failure_message": "Card was declined: insufficient funds"
      }
    }
  }
}
```

**Processing Steps**:
1. Receive webhook with failed payment
2. Parse failure code and message
3. Update payment intent to `failed`
4. Keep booking in `pending` state
5. Log failure reason for analytics

**Expected Outcome**:
- Payment marked as failed
- User can retry payment
- Clear error message available

**Assertions**:
- `payment_intents.status` = `'failed'`
- `bookings.status` = `'pending'`
- Failure reason stored in webhook data

---

### Scenario 5: Webhook Signature Validation
**ID**: `webhook_005_signature_validation`
**Status**: Ready for implementation
**Description**: System rejects webhook with invalid signature

**Webhook Request**:
- Valid Square webhook format
- Invalid `X-Square-HMAC-SHA256` signature header

**Processing Steps**:
1. Webhook endpoint receives request
2. Calculate expected signature using webhook key
3. Compare with header signature
4. Reject if signatures don't match
5. Return 403 Forbidden

**Expected Outcome**:
- Webhook rejected with 403 status
- Event not processed
- Security breach prevented

**Assertions**:
- Invalid signature detected
- Webhook not inserted into database
- 403 response returned
- Log security event

---

### Scenario 6: Duplicate Webhook Handling
**ID**: `webhook_006_duplicate_handling`
**Status**: Ready for implementation
**Description**: Square retransmits same webhook (idempotency)

**Scenario**:
1. First webhook transmitted successfully
2. Square doesn't receive ACK (simulated)
3. Square retransmits identical webhook
4. System receives duplicate

**Processing Steps**:
1. Receive first webhook, process and store
2. Receive second identical webhook
3. Check webhook ID/timestamp in database
4. Detect duplicate by `webhook_events.id`
5. Return 200 OK without reprocessing

**Expected Outcome**:
- Duplicate detected and not processed twice
- Single payment intent update
- No duplicate state changes
- Both requests return 200 OK

**Assertions**:
- Only one `webhook_events` record per unique webhook ID
- No duplicate payment processing
- `webhook_events.id` is unique constraint
- Idempotency key prevents race conditions

---

## Webhook Event Assertions Checklist

- [ ] All scenarios have unique scenario IDs
- [ ] Webhook payloads match Square API v1.0 format
- [ ] Signature validation required for security
- [ ] Duplicate webhook handling implemented
- [ ] All webhook types covered (created, updated, deleted)
- [ ] Payment state transitions documented
- [ ] Error scenarios included (failed, refund)
- [ ] Webhook URL and signing key required for full testing
- [ ] Webhook logs captured for debugging

## Next Steps
- Configure Square webhook endpoint in test environment
- Implement HMAC-SHA256 signature verification
- Set up webhook event logging/debugging
- Test with actual Square sandbox webhook simulator
- Document webhook retry and timeout policies
