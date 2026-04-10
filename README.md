# Background Request Processing System (Rails + Sidekiq)

## Overview

A **fault-tolerant, idempotent background request processing service** built with Ruby on Rails and Sidekiq. The system accepts API requests, processes them asynchronously via background jobs, and handles real-world failure scenarios including retries, duplicate requests, concurrency conflicts, and downstream failures.

> **Core Principle:** The database is the source of truth, and request processing is a state machine.

---

## Table of Contents

- [Tech Stack](#tech-stack)
- [High-Level Architecture](#high-level-architecture)
- [Project Structure](#project-structure)
- [Setup & Installation](#setup--installation)
- [Running the Application](#running-the-application)
- [API Documentation](#api-documentation)
- [Sample Requests (cURL)](#sample-requests-curl)
- [End-to-End Testing Guide](#end-to-end-testing-guide)
- [Design Decisions](#design-decisions)
- [Data Model](#data-model)
- [State Machine](#state-machine)
- [Idempotency Strategy](#idempotency-strategy)
- [Background Processing](#background-processing)
- [Concurrency Control](#concurrency-control)
- [Retry Strategy](#retry-strategy)
- [Failure & Cancellation Handling](#failure--cancellation-handling)
- [Simulation Strategy](#simulation-strategy)
- [Logging & Observability](#logging--observability)
- [Edge Cases Covered](#edge-cases-covered)

---

## Tech Stack

| Component        | Technology              |
| ---------------- | ----------------------- |
| Framework        | Ruby on Rails 8.0       |
| Language         | Ruby 3.3.3              |
| Database         | PostgreSQL              |
| Background Jobs  | Sidekiq                 |
| In-Memory Store  | Redis                   |
| Authentication   | Base64-encoded API Key  |

---

## High-Level Architecture

```
Client (cURL / Postman)
  │
  ▼
┌──────────────────────────────────┐
│  Rails API  (POST /api/v1/...)   │
│  • Idempotency check             │
│  • Payload validation            │
│  • Auth (Bearer token)           │
└──────────┬───────────────────────┘
           │
           ▼
┌──────────────────────────────────┐
│  PostgreSQL                      │
│  • Unique index on               │
│    idempotency_key               │
│  • Status tracking               │
│  • Row-level locking             │
└──────────┬───────────────────────┘
           │
           ▼
┌──────────────────────────────────┐
│  Sidekiq Worker (ApiRequestJob)  │
│  • Acquire DB lock               │
│  • Simulate external API call    │
│  • Handle success / failure      │
│  • Exponential backoff retries   │
└──────────┬───────────────────────┘
           │
           ▼
┌──────────────────────────────────┐
│  State persisted back to DB      │
│  (succeeded / failed / aborted)  │
└──────────────────────────────────┘
```

---

## Project Structure

```
sample-rails/
├── app/
│   ├── controllers/
│   │   ├── application_controller.rb      # Base API controller
│   │   └── api/v1/
│   │       └── requests_controller.rb     # REST endpoints (create, show, cancel)
│   ├── models/
│   │   └── request.rb                     # State machine, validations, transitions
│   └── sidekiq/
│       └── api_request_job.rb             # Background job with retry logic
├── config/
│   ├── routes.rb                          # API routes
│   ├── database.yml                       # PostgreSQL configuration
│   └── initializers/
│       └── sidekiq.rb                     # Sidekiq Redis configuration
├── db/
│   ├── migrate/
│   │   └── 20260327172159_create_requests.rb  # Requests table migration
│   └── schema.rb                          # Current schema
├── .env                                   # Environment variables
├── Gemfile                                # Dependencies
└── README.md                             # This file
```

---

## Setup & Installation

### Prerequisites

- **Ruby** 3.3.3
- **Rails** 8.0
- **PostgreSQL** (running on localhost:5432)
- **Redis** (running on localhost:6379)
- **Bundler**

### 1. Clone the repository

```bash
git clone <repository-url>
cd sample-rails
```

### 2. Install dependencies

```bash
bundle install
```

### 3. Configure environment variables

Create a `.env` file in the project root (or edit the existing one):

```bash
export DEV_DB_NAME=sample_rails
export DEV_DB_USER=postgres
export DEV_DB_PASSWORD=postgres
export DEV_DB_HOST=127.0.0.1

export API_KEY=admin:s3cr31
export PORT=1235
```

Load the variables:

```bash
source .env
```

### 4. Setup the database

```bash
rails db:create
rails db:migrate
```

### 5. Start Redis

```bash
redis-server
```

---

## Running the Application

You need **three terminal windows** (or use a process manager like `foreman`):

### Terminal 1 — Rails Server

```bash
source .env
rails server -p 1235
```

### Terminal 2 — Sidekiq Worker

```bash
source .env
bundle exec sidekiq
```

### Terminal 3 — Making API Requests

Use `curl` or Postman (see [Sample Requests](#sample-requests-curl) below).

### Sidekiq Web UI

Monitor background jobs at: [http://localhost:1235/sidekiq](http://localhost:1235/sidekiq)

---

## API Documentation

### Authentication

All endpoints require a **Bearer token** in the `Authorization` header. The token is the Base64-encoded value of the `API_KEY` environment variable.

```
API_KEY = admin:s3cr31
Token   = Base64("admin:s3cr31") = YWRtaW46czNjcjMx
Header  = Authorization: Bearer YWRtaW46czNjcjMx
```

---

### Endpoints

| Method | Endpoint                        | Description               |
| ------ | ------------------------------- | ------------------------- |
| POST   | `/api/v1/requests`              | Create a new request      |
| GET    | `/api/v1/requests/:id`          | Get request status        |
| POST   | `/api/v1/requests/:id/cancel`   | Cancel a pending request  |

---

### POST `/api/v1/requests`

Creates a new request and enqueues a background job for processing.

**Headers:**

| Header           | Required | Description                                  |
| ---------------- | -------- | -------------------------------------------- |
| Authorization    | Yes      | `Bearer YWRtaW46czNjcjMx`                   |
| Content-Type     | Yes      | `application/json`                           |
| Idempotency-Key  | Yes      | Unique key to prevent duplicate processing   |

**Body Parameters:**

| Parameter    | Type    | Required | Description                                      |
| ------------ | ------- | -------- | ------------------------------------------------ |
| type         | string  | Yes      | The type of request (e.g., `payment`, `order`)   |
| external_id  | integer | Yes      | External reference ID (determines simulation)    |
| retry_count  | integer | No       | Max retry attempts (default: 5)                  |

**Response Codes:**

| Status | Meaning                                          |
| ------ | ------------------------------------------------ |
| 202    | Request accepted and queued for processing       |
| 200    | Duplicate request — already completed            |
| 400    | Missing Idempotency-Key or invalid payload       |
| 401    | Unauthorized — invalid or missing auth token     |
| 409    | Idempotency key reused with a different payload  |

---

### GET `/api/v1/requests/:id`

Retrieves the current status and details of a request.

**Response Codes:**

| Status | Meaning            |
| ------ | ------------------ |
| 200    | Request found      |
| 401    | Unauthorized       |
| 404    | Request not found  |

---

### POST `/api/v1/requests/:id/cancel`

Cancels a request that hasn't reached a terminal state.

**Response Codes:**

| Status | Meaning                                  |
| ------ | ---------------------------------------- |
| 200    | Request cancelled successfully           |
| 401    | Unauthorized                             |
| 404    | Request not found                        |
| 409    | Cannot cancel — already in terminal state|

---

## Sample Requests (cURL)

> **Note:** All examples assume the server is running on `http://localhost:1235` with `API_KEY=admin:s3cr31`.

### 1. Create a Request — Success Path (`external_id % 5 == 0` → 200)

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YWRtaW46czNjcjMx" \
  -H "Idempotency-Key: test-success-001" \
  -d '{
    "type": "payment",
    "external_id": 10,
    "retry_count": 3
  }'
```

**Expected Response (202 Accepted):**

```json
{
  "request_id": 1,
  "status": "pending",
  "attempts": 0,
  "response": null,
  "error_message": null
}
```

After Sidekiq processes it, query the status:

```bash
curl -X GET http://localhost:1235/api/v1/requests/1 \
  -H "Authorization: Bearer YWRtaW46czNjcjMx"
```

**Expected Response (200 OK) — after processing:**

```json
{
  "request_id": 1,
  "status": "succeeded",
  "attempts": 0,
  "response": {
    "type": "payment",
    "id": 10,
    "data": "Sample response"
  },
  "error_message": null
}
```

---

### 2. Create a Request — Server Error + Retry Path (`external_id % 5 == 1` → 500)

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YWRtaW46czNjcjMx" \
  -H "Idempotency-Key: test-retry-500" \
  -d '{
    "type": "order",
    "external_id": 11,
    "retry_count": 3
  }'
```

**Expected Behavior:**
- Returns `202 Accepted` immediately
- Sidekiq retries with exponential backoff (4s, 16s, 64s...)
- After `max_attempts` exhausted → status becomes `failed`

**Check status to see retry progress:**

```bash
curl -X GET http://localhost:1235/api/v1/requests/2 \
  -H "Authorization: Bearer YWRtaW46czNjcjMx"
```

**Expected Response (during retries):**

```json
{
  "request_id": 2,
  "status": "pending",
  "attempts": 1,
  "response": null,
  "error_message": "Retryable error: 500"
}
```

**Expected Response (after retries exhausted):**

```json
{
  "request_id": 2,
  "status": "failed",
  "attempts": 3,
  "response": null,
  "error_message": "Final failure: 500"
}
```

---

### 3. Create a Request — Rate Limited + Retry Path (`external_id % 5 == 2` → 429)

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YWRtaW46czNjcjMx" \
  -H "Idempotency-Key: test-retry-429" \
  -d '{
    "type": "notification",
    "external_id": 12,
    "retry_count": 3
  }'
```

**Expected Behavior:**
- Returns `202 Accepted` immediately
- 429 is retryable → Sidekiq retries with exponential backoff
- Eventually fails after `max_attempts`

---

### 4. Create a Request — Forbidden / No Retry (`external_id % 5 == 3` → 403)

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YWRtaW46czNjcjMx" \
  -H "Idempotency-Key: test-no-retry-403" \
  -d '{
    "type": "refund",
    "external_id": 13
  }'
```

**Expected Behavior:**
- Returns `202 Accepted` immediately
- 403 is **not retryable** → immediately marked as `failed`

**Check status:**

```bash
curl -X GET http://localhost:1235/api/v1/requests/4 \
  -H "Authorization: Bearer YWRtaW46czNjcjMx"
```

**Expected Response:**

```json
{
  "request_id": 4,
  "status": "failed",
  "attempts": 1,
  "response": null,
  "error_message": "Final failure: 403"
}
```

---

### 5. Create a Request — Bad Request / No Retry (`external_id % 5 == 4` → 400)

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YWRtaW46czNjcjMx" \
  -H "Idempotency-Key: test-no-retry-400" \
  -d '{
    "type": "webhook",
    "external_id": 14
  }'
```

**Expected Behavior:**
- Returns `202 Accepted` immediately
- 400 is **not retryable** → immediately marked as `failed`

---

### 6. Duplicate Request — Same Payload (Idempotent)

Send the **exact same request** as #1 again:

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YWRtaW46czNjcjMx" \
  -H "Idempotency-Key: test-success-001" \
  -d '{
    "type": "payment",
    "external_id": 10,
    "retry_count": 3
  }'
```

**Expected Response (200 OK — if already completed):**

```json
{
  "request_id": 1,
  "status": "succeeded",
  "attempts": 0,
  "response": {
    "type": "payment",
    "id": 10,
    "data": "Sample response"
  },
  "error_message": null
}
```

**Expected Response (202 Accepted — if still processing):**

```json
{
  "request_id": 1,
  "status": "processing",
  "attempts": 0,
  "response": null,
  "error_message": null
}
```

---

### 7. Duplicate Request — Different Payload (Conflict)

Reuse the same idempotency key but change the payload:

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YWRtaW46czNjcjMx" \
  -H "Idempotency-Key: test-success-001" \
  -d '{
    "type": "refund",
    "external_id": 99
  }'
```

**Expected Response (409 Conflict):**

```json
{
  "error": "Idempotency key reuse with different payload"
}
```

---

### 8. Cancel a Request

First, create a request that will retry (giving you time to cancel it):

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YWRtaW46czNjcjMx" \
  -H "Idempotency-Key: test-cancel-001" \
  -d '{
    "type": "order",
    "external_id": 11,
    "retry_count": 5
  }'
```

Then cancel it (replace `5` with the actual request ID):

```bash
curl -X POST http://localhost:1235/api/v1/requests/5/cancel \
  -H "Authorization: Bearer YWRtaW46czNjcjMx"
```

**Expected Response (200 OK):**

```json
{
  "request_id": 5,
  "status": "aborted",
  "attempts": 1,
  "response": null,
  "error_message": "Retryable error: 500"
}
```

---

### 9. Cancel an Already Completed Request (Conflict)

```bash
curl -X POST http://localhost:1235/api/v1/requests/1/cancel \
  -H "Authorization: Bearer YWRtaW46czNjcjMx"
```

**Expected Response (409 Conflict):**

```json
{
  "error": "Cannot cancel a completed request",
  "status": "succeeded"
}
```

---

### 10. Missing Idempotency Key

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YWRtaW46czNjcjMx" \
  -d '{
    "type": "payment",
    "external_id": 10
  }'
```

**Expected Response (400 Bad Request):**

```json
{
  "error": "Missing Idempotency-Key"
}
```

---

### 11. Invalid Payload (Missing Required Fields)

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YWRtaW46czNjcjMx" \
  -H "Idempotency-Key: test-invalid-001" \
  -d '{
    "type": "payment"
  }'
```

**Expected Response (400 Bad Request):**

```json
{
  "error": "Invalid payload"
}
```

---

### 12. Unauthorized Request (Wrong Token)

```bash
curl -X POST http://localhost:1235/api/v1/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer INVALID_TOKEN" \
  -H "Idempotency-Key: test-unauth-001" \
  -d '{
    "type": "payment",
    "external_id": 10
  }'
```

**Expected Response (401 Unauthorized):**

```json
{
  "error": "Unauthorized"
}
```

---

### 13. Request Not Found

```bash
curl -X GET http://localhost:1235/api/v1/requests/99999 \
  -H "Authorization: Bearer YWRtaW46czNjcjMx"
```

**Expected Response (404 Not Found):**

```json
{
  "error": "Request not found"
}
```

---

## End-to-End Testing Guide

### Quick Smoke Test

Run these commands in order to validate the full flow:

```bash
# Step 1: Set up the auth token
AUTH="Authorization: Bearer YWRtaW46czNjcjMx"
BASE="http://localhost:1235/api/v1"

# Step 2: Create a request that will succeed (external_id=10 → 200)
curl -s -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Idempotency-Key: smoke-test-$(date +%s)" \
  -d '{"type": "payment", "external_id": 10}' | python3 -m json.tool

# Step 3: Wait a few seconds for Sidekiq to process
sleep 3

# Step 4: Check the status (replace ID with actual from step 2)
curl -s -X GET $BASE/requests/1 \
  -H "$AUTH" | python3 -m json.tool
```

### Testing Each Scenario

Below is a comprehensive test script. Copy and run it in your terminal:

```bash
#!/bin/bash
AUTH="Authorization: Bearer YWRtaW46czNjcjMx"
BASE="http://localhost:1235/api/v1"
TIMESTAMP=$(date +%s)

echo "=========================================="
echo "  End-to-End Test Suite"
echo "=========================================="

echo ""
echo "--- TEST 1: Success Path (external_id=10 → 200) ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Idempotency-Key: e2e-success-$TIMESTAMP" \
  -d '{"type": "payment", "external_id": 10}'

echo ""
echo "--- TEST 2: Server Error Path (external_id=11 → 500, retryable) ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Idempotency-Key: e2e-500-$TIMESTAMP" \
  -d '{"type": "order", "external_id": 11, "retry_count": 2}'

echo ""
echo "--- TEST 3: Rate Limited Path (external_id=12 → 429, retryable) ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Idempotency-Key: e2e-429-$TIMESTAMP" \
  -d '{"type": "notification", "external_id": 12, "retry_count": 2}'

echo ""
echo "--- TEST 4: Forbidden Path (external_id=13 → 403, non-retryable) ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Idempotency-Key: e2e-403-$TIMESTAMP" \
  -d '{"type": "refund", "external_id": 13}'

echo ""
echo "--- TEST 5: Bad Request Path (external_id=14 → 400, non-retryable) ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Idempotency-Key: e2e-400-$TIMESTAMP" \
  -d '{"type": "webhook", "external_id": 14}'

echo ""
echo "--- TEST 6: Duplicate Request (same idempotency key) ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Idempotency-Key: e2e-success-$TIMESTAMP" \
  -d '{"type": "payment", "external_id": 10}'

echo ""
echo "--- TEST 7: Idempotency Key Conflict (same key, different payload) ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Idempotency-Key: e2e-success-$TIMESTAMP" \
  -d '{"type": "refund", "external_id": 99}'

echo ""
echo "--- TEST 8: Missing Idempotency Key ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -d '{"type": "payment", "external_id": 10}'

echo ""
echo "--- TEST 9: Invalid Payload ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Idempotency-Key: e2e-invalid-$TIMESTAMP" \
  -d '{"type": "payment"}'

echo ""
echo "--- TEST 10: Unauthorized ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer WRONG" \
  -H "Idempotency-Key: e2e-unauth-$TIMESTAMP" \
  -d '{"type": "payment", "external_id": 10}'

echo ""
echo "--- TEST 11: Cancellation ---"
CANCEL_RESPONSE=$(curl -s -X POST $BASE/requests \
  -H "Content-Type: application/json" \
  -H "$AUTH" \
  -H "Idempotency-Key: e2e-cancel-$TIMESTAMP" \
  -d '{"type": "order", "external_id": 11, "retry_count": 5}')
CANCEL_ID=$(echo $CANCEL_RESPONSE | python3 -c "import sys,json; print(json.load(sys.stdin)['request_id'])" 2>/dev/null)
echo "Created request $CANCEL_ID for cancellation"
sleep 5
curl -s -w "\nHTTP Status: %{http_code}\n" -X POST $BASE/requests/$CANCEL_ID/cancel \
  -H "$AUTH"

echo ""
echo "--- TEST 12: Request Not Found ---"
curl -s -w "\nHTTP Status: %{http_code}\n" -X GET $BASE/requests/99999 \
  -H "$AUTH"

echo ""
echo "=========================================="
echo "  Waiting 5s for Sidekiq to process..."
echo "=========================================="
sleep 5

echo ""
echo "--- Check statuses after processing ---"
echo "Use: curl -s $BASE/requests/<ID> -H \"$AUTH\" | python3 -m json.tool"
echo ""
```

### Using Rails Console for Inspection

```bash
source .env
rails console
```

```ruby
# Check all requests
Request.all.pluck(:id, :idempotency_key, :status, :attempts, :error_message)

# Check by status
Request.pending.count
Request.processing.count
Request.succeeded.count
Request.failed.count
Request.aborted.count

# Check stale/stuck jobs (processing for > 5 minutes)
Request.stale.count

# Inspect a specific request
Request.find(1).attributes
```

### Reset Database for Clean Testing

```bash
rails db:reset
```

---

## Design Decisions

### 1. Custom Retry Logic (Sidekiq retries disabled)

**Decision:** `sidekiq_options retry: false` — retries are managed explicitly in application code.

**Rationale:**
- Allows tracking retry attempts in the database
- Ensures consistent state transitions
- Enables fine-grained control per status code (e.g., retry on 429/500 but not on 400/403)

### 2. Database as Source of Truth

**Decision:** All state transitions are persisted to PostgreSQL.

**Rationale:**
- Enables recovery after worker crashes
- Makes the system observable and debuggable
- Provides audit trail of all state changes

### 3. Idempotency via DB Unique Constraint

**Decision:** `idempotency_key` has a unique index at the database level.

**Rationale:**
- Database-level enforcement is race-condition-proof
- Application handles `RecordNotUnique` exceptions gracefully
- Concurrent duplicate requests are safely resolved

### 4. Row-Level Locking for Concurrency

**Decision:** `with_lock` (PostgreSQL `SELECT ... FOR UPDATE`) for all state transitions.

**Rationale:**
- Prevents duplicate execution of the same job
- Ensures atomic state changes
- Avoids lost updates from concurrent workers

### 5. Deterministic Simulation

**Decision:** External API responses are determined by `external_id % 5`.

**Rationale:**
- Predictable and reproducible for testing
- Covers all response scenarios (200, 400, 403, 429, 500)
- Easy to trigger specific edge cases

---

## Data Model

### `requests` Table

| Column          | Type     | Default     | Constraints | Purpose                         |
| --------------- | -------- | ----------- | ----------- | ------------------------------- |
| id              | bigint   | auto        | PK          | Primary key                     |
| idempotency_key | string   | —           | NOT NULL, UNIQUE | Deduplication identifier    |
| status          | string   | `pending`   | NOT NULL    | Lifecycle state                 |
| request_type    | string   | —           | NOT NULL    | Type of request                 |
| external_id     | integer  | —           | NOT NULL    | External reference / sim key    |
| attempts        | integer  | `0`         | NOT NULL    | Current retry count             |
| max_attempts    | integer  | `5`         | NOT NULL    | Maximum retries allowed         |
| payload         | jsonb    | `{}`        | NOT NULL    | Arbitrary request payload       |
| error_message   | string   | `null`      |             | Last error description          |
| response        | jsonb    | `null`      |             | Successful response data        |
| locked_at       | datetime | `null`      |             | Concurrency lock timestamp      |
| lock_version    | integer  | `0`         | NOT NULL    | Optimistic locking counter      |
| created_at      | datetime | auto        | NOT NULL    | Record creation time            |
| updated_at      | datetime | auto        | NOT NULL    | Last modification time          |

**Indexes:**
- `UNIQUE` on `idempotency_key` — prevents duplicate processing
- `INDEX` on `status` — efficient status queries

---

## State Machine

```
                    ┌─────────────────────────────────────┐
                    │                                     │
                    ▼                                     │
  ┌─────────┐   ┌──────────┐   ┌───────────┐            │
  │ pending  │──▶│processing│──▶│ succeeded │            │
  └─────────┘   └──────────┘   └───────────┘            │
       ▲             │                                    │
       │             ├──────────▶┌────────┐              │
       │             │           │ failed │              │
       │             │           └────────┘              │
       │             │                                    │
       │             └──────────▶┌─────────┐             │
       │                         │ aborted │             │
       │                         └─────────┘             │
       │                                                  │
       └──────────────── (retry) ─────────────────────────┘
```

| Transition | Trigger | Condition |
| --- | --- | --- |
| pending → processing | Job picks up the request | `safe_to_process?` passes |
| processing → succeeded | External call returns 200 | Not already terminal |
| processing → failed | Non-retryable error or retries exhausted | `!retryable_status?` or `attempts >= max_attempts` |
| processing → pending | Retryable error | `retryable_status?` and `attempts < max_attempts` |
| any non-terminal → aborted | User cancels via API | Not already in terminal state |

---

## Idempotency Strategy

### How It Works

1. Client sends an `Idempotency-Key` header with each request
2. If no existing record → create new request, return `202 Accepted`
3. If existing record with same payload → return current state (`200` or `202`)
4. If existing record with different payload → return `409 Conflict`

### Race Condition Handling

```ruby
begin
  request = Request.create!(idempotency_key: key, ...)
rescue ActiveRecord::RecordNotUnique
  # A concurrent request beat us — find and return the existing one
  request = Request.find_by!(idempotency_key: key)
  return handle_existing_request(request)
end
```

---

## Background Processing

### Execution Flow (ApiRequestJob)

1. **Fetch** the request record from DB
2. **Skip** if already completed or aborted
3. **Acquire** a row-level DB lock (`with_lock`)
4. **Verify** the request is still retryable (hasn't exceeded `max_attempts`)
5. **Simulate** external API call (based on `external_id % 5`)
6. **Handle** result: success → `succeeded`, retryable error → retry, non-retryable → `failed`

### Re-enqueue with Exponential Backoff

```ruby
def backoff_time(attempts)
  (4 ** attempts).seconds  # 4s, 16s, 64s, 256s, ...
end
```

---

## Concurrency Control

| Mechanism | Where | Purpose |
| --- | --- | --- |
| `with_lock` (row-level lock) | Job execution | Prevents duplicate processing |
| State checks (`terminal?`, `safe_to_process?`) | Before every transition | Guards against invalid transitions |
| `locked_at` timestamp | `safe_to_process?` | Detects stale locks (> 30s) |
| Unique index on `idempotency_key` | DB level | Prevents duplicate records |

---

## Retry Strategy

Retries are **explicitly managed in application code**, not delegated to Sidekiq.

### Retry Rules by Status Code

| Status Code | Retryable? | Action |
| --- | --- | --- |
| 200 | N/A | Mark as `succeeded` |
| 400 | ❌ No | Mark as `failed` immediately |
| 403 | ❌ No | Mark as `failed` immediately |
| 429 | ✅ Yes | Re-enqueue with backoff |
| 500 | ✅ Yes | Re-enqueue with backoff |
| 502 | ✅ Yes | Re-enqueue with backoff |
| 503 | ✅ Yes | Re-enqueue with backoff |

### Backoff Schedule

| Attempt | Delay |
| ------- | ----- |
| 1       | 4s    |
| 2       | 16s   |
| 3       | 64s   |
| 4       | 256s  |
| 5       | 1024s |

---

## Failure & Cancellation Handling

### Failure Categories

| Category | Example | Action |
| --- | --- | --- |
| Recoverable | 429 Rate Limit, 500 Server Error | Retry with backoff |
| Non-recoverable | 400 Bad Request, 403 Forbidden | Mark as `failed` |
| Retries exhausted | Max attempts reached | Mark as `failed` |
| User-initiated | Cancel API called | Mark as `aborted` |
| Unexpected exception | Code error, timeout | Retry if possible, else `failed` |

### Cancellation

- Users cancel via `POST /api/v1/requests/:id/cancel`
- The controller acquires a lock and sets status to `aborted`
- Background workers check for `aborted?` before every state transition and exit early
- Cancellation of a terminal request returns `409 Conflict`

---

## Simulation Strategy

External API responses are **deterministic** based on `external_id`:

```ruby
case request.external_id % 5
when 0 then { status: 200, body: fetch_real_data(request) }  # Success
when 1 then { status: 500 }                                   # Server error (retryable)
when 2 then { status: 429 }                                   # Rate limited (retryable)
when 3 then { status: 403 }                                   # Forbidden (non-retryable)
else        { status: 400 }                                   # Bad request (non-retryable)
end
```

**Quick Reference:**

| external_id examples | Simulated Status | Retryable? |
| -------------------- | ---------------- | ---------- |
| 0, 5, 10, 15, 20    | 200 Success      | N/A        |
| 1, 6, 11, 16, 21    | 500 Server Error | ✅ Yes      |
| 2, 7, 12, 17, 22    | 429 Rate Limited | ✅ Yes      |
| 3, 8, 13, 18, 23    | 403 Forbidden    | ❌ No       |
| 4, 9, 14, 19, 24    | 400 Bad Request  | ❌ No       |

---

## Logging & Observability

All logs are tagged with `request_id` and `idempotency_key` for traceability:

```ruby
Rails.logger.tagged("request_id=#{request.id}", "key=#{request.idempotency_key}") do
  Rails.logger.info("attempts: #{request.attempts}/#{request.max_attempts}")
end
```

**What is logged:**
- Request creation
- Job acquisition and state transitions
- External API simulation results
- Retry scheduling with delay
- Final success or failure outcomes
- Error messages and exception backtraces

**Sidekiq Web UI** at `/sidekiq` provides:
- Queue depth and latency
- Scheduled/retry job counts
- Failed job inspection
- Real-time worker activity

---

## Edge Cases Covered

| # | Edge Case | How It's Handled |
| - | --------- | ---------------- |
| 1 | **Duplicate requests** | Unique DB constraint on `idempotency_key` + `RecordNotUnique` rescue |
| 2 | **Retry duplication** | Custom retry logic (Sidekiq retries disabled); state check before processing |
| 3 | **Downstream failure** | Categorized by status code; retryable vs non-retryable paths |
| 4 | **User cancellation** | `POST /:id/cancel` sets `aborted`; workers check before every transition |
| 5 | **Concurrent updates** | Row-level locking (`with_lock` / `SELECT FOR UPDATE`) |
| 6 | **Slow processing** | `locked_at` timestamp; stale lock detection (30s timeout) |
| 7 | **Data corruption** | DB-level constraints (`NOT NULL`, `CHECK`); validations in model |
| 8 | **When NOT to retry** | 400 and 403 are non-retryable; retry limit enforced via `max_attempts` |
| 9 | **Race condition on create** | `RecordNotUnique` rescue falls through to find existing record |
| 10 | **Worker crash** | Stale lock detection; request stays in `processing` and can be recovered |

---

## What This System Guarantees

- ✅ **No duplicate processing** — idempotency key + DB lock
- ✅ **Safe retries** — explicit retry management with attempt tracking
- ✅ **Consistent state** — all transitions are atomic and locked
- ✅ **Recoverability** — stale lock detection, state persisted in DB
- ✅ **Observability** — tagged logging, Sidekiq Web UI
