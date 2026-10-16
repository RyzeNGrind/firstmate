/**
 * E2E Test Helpers for nv-m3 Phase 1
 * Provides utility functions for booking and checkout flow testing
 */

import { Pool, PoolClient } from 'pg';

export interface TestPaymentIntent {
  id: string;
  bookingId: string;
  amount: number;
  currency: 'USD';
  status: 'pending' | 'completed' | 'failed';
  squareRequestId?: string;
}

export interface TestBooking {
  id: string;
  userId: string;
  serviceId: string;
  scheduledTime: Date;
  status: 'pending' | 'confirmed' | 'cancelled';
}

export interface TestWebhookEvent {
  id: string;
  type: string;
  data: Record<string, unknown>;
  processed: boolean;
}

/**
 * Initialize test database connection
 */
export async function initTestDb(connectionString: string): Promise<PoolClient> {
  const pool = new Pool({ connectionString });
  const client = await pool.connect();
  return client;
}

/**
 * Load test fixtures from SQL file
 */
export async function loadTestFixtures(client: PoolClient, sqlContent: string): Promise<void> {
  await client.query(sqlContent);
}

/**
 * Create a test payment intent
 */
export async function createTestPaymentIntent(
  client: PoolClient,
  intent: TestPaymentIntent
): Promise<TestPaymentIntent> {
  const query = `
    INSERT INTO payment_intents (id, booking_id, amount, currency, status, square_request_id)
    VALUES ($1, $2, $3, $4, $5, $6)
    RETURNING *
  `;
  const result = await client.query(query, [
    intent.id,
    intent.bookingId,
    intent.amount,
    intent.currency,
    intent.status,
    intent.squareRequestId || null,
  ]);
  return result.rows[0];
}

/**
 * Retrieve a test booking by ID
 */
export async function getTestBooking(client: PoolClient, bookingId: string): Promise<TestBooking | null> {
  const query = 'SELECT * FROM bookings WHERE id = $1';
  const result = await client.query(query, [bookingId]);
  return result.rows[0] || null;
}

/**
 * Simulate a Square webhook event
 */
export async function simulateWebhookEvent(
  client: PoolClient,
  event: TestWebhookEvent
): Promise<TestWebhookEvent> {
  const query = `
    INSERT INTO webhook_events (id, type, data, processed)
    VALUES ($1, $2, $3, $4)
    RETURNING *
  `;
  const result = await client.query(query, [event.id, event.type, JSON.stringify(event.data), event.processed]);
  return result.rows[0];
}

/**
 * Cleanup test data
 */
export async function cleanupTestData(client: PoolClient): Promise<void> {
  await client.query('DELETE FROM webhook_events');
  await client.query('DELETE FROM payment_intents');
  await client.query('DELETE FROM bookings');
  await client.query('DELETE FROM users');
}

/**
 * Close database connection
 */
export async function closeTestDb(client: PoolClient): Promise<void> {
  await client.end();
}
