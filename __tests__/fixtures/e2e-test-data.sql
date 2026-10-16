-- E2E Test Data for nv-m3 Booking & Square Checkout Phase 1
-- This file initializes the test database with sample data for checkout and webhook scenarios

-- Create test user
INSERT INTO users (id, email, name, created_at) VALUES
  ('user_test_001', 'test@example.com', 'Test User', NOW());

-- Create test booking
INSERT INTO bookings (id, user_id, service_id, scheduled_time, status, created_at) VALUES
  ('booking_test_001', 'user_test_001', 'service_001', NOW() + INTERVAL '1 day', 'pending', NOW());

-- Create test payment intent (unfulfilled)
INSERT INTO payment_intents (id, booking_id, amount, currency, status, square_request_id, created_at) VALUES
  ('payment_test_001', 'booking_test_001', 9999, 'USD', 'pending', NULL, NOW());

-- Create test Square webhook event log table (for webhook validation)
CREATE TABLE IF NOT EXISTS webhook_events (
  id VARCHAR(255) PRIMARY KEY,
  type VARCHAR(100) NOT NULL,
  data JSONB NOT NULL,
  processed BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP DEFAULT NOW()
);

-- Insert sample webhook event for testing
INSERT INTO webhook_events (id, type, data, processed) VALUES
  ('webhook_event_001', 'payment.created', '{"payment_id":"sqpay_123","status":"pending"}', FALSE);
