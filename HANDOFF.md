# Ticket Drop - Session Handoff

Date: 2026-11-02
Status: design finished, nothing built yet. Next session = walk through the first build step.

## 1. Goal of the project

Learn microservices hands-on: communication strategies (sync vs async), design patterns
(API gateway, saga, outbox, idempotency, circuit breaker), and how to structure services.
Plan: diagram -> implement each service by hand -> break it on purpose -> stress test -> maybe deploy to AWS.

Guiding principle agreed this session: **keep it small and break it on purpose.**
The lessons come from failure handling, not from the number of services or the domain.
Three core services plus one queue cover ~80% of what matters.

## 2. How the design evolved (and why)

1. **Original sketch (e-commerce):** Payment Service called Stock and Client Info over gRPC and queued an email.
2. **Round 1 feedback:**
   - "Payment Service" was really an Order coordinator -> renamed Order, Payment made its own service.
   - "Check stock" has a race (two buyers both see 1 left) -> Reserve/Release instead, which introduces the saga.
   - Client Info service was an entity-per-noun anti-pattern and leaked card data -> Payment owns payment methods.
   - Added client + API gateway; switched to publishing events to a topic; one DB per service.
3. **Round 2:** Payment and Inventory shared a DB (fixed: separate DBs); Order needed its own DB for order state;
   Client Info turned into a Customer service (contact details for Email); gRPC arrows labelled with calls.
4. **Round 3:** removed leftover Client Info; connected Topic -> Queue -> Email; Reserve should succeed/fail
   atomically, not return the count; noted "orders + outbox" on the Order DB.
5. **Explained concepts:**
   - **Transactional outbox:** write the event into an `outbox` table in the same DB transaction as the order change;
     a relay loop publishes unpublished rows and marks them published. Gives at-least-once delivery, so consumers
     must be idempotent (store processed event IDs).
   - **Topic vs queue:** queue = each message to one consumer (work sharing); topic = each message to every
     subscriber (broadcast). SNS topics fan out into SQS queues. Kafka topics are retained logs that consumers can
     replay. Chosen: **SNS + SQS** (cheap, serverless; LocalStack locally). Kafka deferred.
6. **Scope check:** user felt it was getting boring and big. Agreed to cut scope and reframe as a **concert ticket drop**,
   with a "break it on purpose" learning plan.

## 3. Final design: Ticket Drop

Diagram page (private artifact): https://claude.ai/artifact/BNyDkjoDPT8mhaSrvQoLmA
Local copy of the page: /private/tmp/claude-501/-Users-nanajnashia/51a17824-8193-41a4-8ea3-7ccfdf5876e9/scratchpad/ticket-drop.html (temp dir, may vanish)

**Scenario:** a concert goes on sale at 10:00. 500 tickets, 20,000 buyers.
**Pass criteria:** 0 oversold tickets, 0 charges without a ticket, stays fast under load.

```
Buyer --HTTP POST /orders--> Order [DB: orders PENDING/CONFIRMED/FAILED + outbox]
                               |
        gRPC Hold/Confirm/Release --> Tickets [DB: events.available, holds (expire 10 min)]
        gRPC Charge (idempotency key = order ID) --> Payment [DB: charges keyed by order ID]
                               |
                               | outbox relay publishes OrderConfirmed / OrderFailed
                               v
                         SNS Topic --> SQS Queue (+ DLQ) --> Email (skips seen event IDs)
```

Services:
- **Order** - only service the buyer talks to; runs the saga (orchestration).
- **Tickets** - holds seats. Holds expire after 10 minutes as a safety net; Confirm turns a hold into a sold ticket.
- **Payment** - fake card charges; idempotent by order ID.
- **Email** - consumes events, sends (fake) email, deletes message after sending, dedupes by event ID.
- Buyer's email address goes in the order request (no Customer service for now).

## 4. Checkout flow (the saga)

1. Buyer sends event ID, quantity, email, idempotency key. Order saves order as `PENDING`.
2. Order calls **Hold** on Tickets. Atomic decrement:
   ```sql
   UPDATE events SET available = available - :qty
   WHERE id = :event_id AND available >= :qty;
   -- 0 rows changed = sold out
   ```
   Sold out -> order `FAILED`, emit OrderFailed, return 409.
3. Order calls **Charge** on Payment with order ID as idempotency key.
   - Declined -> **Release** hold (compensation), order `FAILED`, emit OrderFailed.
   - Timed out -> do NOT release; retry Charge with the same key (Payment returns the original result).
4. Order calls **Confirm** on Tickets (hold becomes a sold ticket).
   - Stretch problem: Order crashes after charge but before confirm -> hold expires, buyer charged, no ticket.
     Recovery idea: on restart, scan stuck orders and either confirm or refund.
5. One DB transaction: order `CONFIRMED` + OrderConfirmed row in outbox.
6. Relay publishes to topic; Email reads from queue, skips duplicates, sends, deletes message.

## 5. Break-it-on-purpose plan

Build the plain version first WITHOUT the fixes. Then run each experiment, watch it break, add the fix.

| # | Experiment | What breaks | What you add |
|---|---|---|---|
| 1 | Kill Payment mid-checkout | Seats stay held forever | Release on failure, hold expiry |
| 2 | Add 5s latency to Payment | Requests pile up, Order runs out of connections | Timeouts, circuit breaker |
| 3 | Payment charges, reply is dropped | Retry charges twice | Idempotency key on Charge |
| 4 | Crash Order between save and publish | Confirmed order, no email | Transactional outbox |
| 5 | Deliver the same SQS message twice | Two emails | Idempotent consumer |
| 6 | 20,000 buyers with k6 at 10:00 | Oversell or meltdown | Atomic hold, then measure and tune |

## 6. Deliberately deferred

API gateway, Customer service, OpenTelemetry tracing, AWS deploy with Terraform, Kubernetes, Kafka.
Add them only after the break-it list passes locally.
AWS cost warning: ALB, NAT gateway and RDS cost money while idle; use Terraform so everything can be destroyed after each session. ECS Fargate suggested over Kubernetes for simplicity.

## 7. Open questions (never answered)

- Language: **Go** (confirmed; the whole build so far is Go). One service in PHP is still an option, to show language independence.
- Kubernetes vs ECS for the eventual deploy.
- Time budget per week (decides how far into the stretch goals to go).

## 8. Build progress (as of 6 Nov 2026)

### Done
- **Repo:** `~/projects/ticket-drop`, git on `main`, pushed to https://github.com/nanajanashia/ticket-drop.git.
  There is one commit, "Add gRPC contracts for Tickets and Payment services", authored with the user's
  default git identity (njanashia).
- **Layout:** Go workspace (`go.work`, go 1.26.0) with one module per service: `proto`, `order`,
  `tickets`, `payment`, `email`. Module paths are `github.com/nanajanashia/ticket-drop/<name>`.
  The service modules contain only `go.mod` so far.
- **Tooling:** protoc 36.2 (brew), protoc-gen-go and protoc-gen-go-grpc are in `~/go/bin`.
  Installed Go is 1.25.0. `GOTOOLCHAIN=auto` downloads 1.26 automatically, because grpc v1.85
  requires it. Docker images will need `golang:1.26`.
- **`proto/Makefile`:** `make generate` runs protoc on `$(wildcard */*.proto)` with
  `paths=source_relative`. The generated `.pb.go` files are committed.
- **`proto/tickets/tickets.proto`** (package `tickets`, no v1 suffix, by the user's choice):
  - `Hold(HoldRequest{event_id int64, order_id int64, quantity int32})` returns
    `HoldResponse{hold_status HoldStatus, expires_at google.protobuf.Timestamp}`.
    `HoldStatus` is UNSPECIFIED / SUCCESS / EXHAUSTED.
  - `Confirm(ConfirmRequest{order_id})` returns `ConfirmResponse{confirm_status ConfirmStatus}`.
    `ConfirmStatus` is UNSPECIFIED / SUCCESS / EXPIRED.
  - `Release(ReleaseRequest{order_id})` returns `ReleaseResponse{}` (empty).
- **`proto/payment/payment.proto`** (package `payment`):
  - `Charge(ChargeRequest{order_id, amount_minor int64, currency string, payment_token string})`
    returns `ChargeResponse{charge_status ChargeStatus}`. `ChargeStatus` is UNSPECIFIED / SUCCESS / DECLINED.
  - `Refund(RefundRequest{order_id})` returns `RefundResponse{}` (empty).
- `cd proto && make generate && go build ./...` runs clean with no warnings.

### In progress: the async event contract
Next is `proto/events/events.proto` with an `OrderConfirmed` message. Order publishes it to SNS as
JSON via `protojson`, and Email consumes it from SQS. **The open question put to the user, not yet
answered:** "What fields does OrderConfirmed need, given that Email has no access to Order's or
Tickets' data and can't look anything up?" Answers to steer towards:
- `event_id`, a unique ID per event. Email needs it to dedupe at-least-once delivery
  (experiment 5). This is distinct from order_id.
- `order_id`, buyer email address, event name or ID, quantity, and amount and currency for a receipt.
  The event must carry everything Email needs (event-carried state), because there is no
  callback to Order.
- Optionally `occurred_at` (a Timestamp).
Teaching points for this step: async contracts have no compiler between producer and consumer;
adding fields is safe and removing or renumbering them is not; and the event describes a fact
in the past tense ("OrderConfirmed"), not a command ("SendEmail").

### Remaining steps after the event contract
1. docker-compose: one Postgres with a separate DB and user per service, plus LocalStack (SNS+SQS).
2. Tickets service: schema (events.available, holds with order_id UNIQUE and a status column
   HELD/CONFIRMED/RELEASED plus expires_at) and the gRPC server, following the decisions log.
3. Payment service: schema (charges with order_id UNIQUE, status) and a fake processor
   (`tok_decline` always declines) plus Refund.
4. Order: HTTP `POST /orders` inserts a PENDING row, then Hold, then a check on remaining time
   against expires_at, then Charge, then Confirm. Each failure branch runs its compensation. It
   publishes to SNS directly at first, with no outbox, so experiment 4 shows the bug.
5. Email: an SQS long-polling consumer that logs the email.
6. Happy-path curl test, then experiment 1 (kill Payment mid-checkout).

## 9. How to guide the user (important; read this first)

The user is an experienced backend developer (8+ years, Go/PHP). Don't explain basics like Docker,
SQL or HTTP. They have little prior proto/gRPC experience. They had to learn what a .proto file
is, and that `service` generates a Go interface.

**Interaction rules (the user insisted on these after the first walkthrough was too much at once):**
- Go strictly one small step per message. Ask one question at a time and wait for the answer.
- Explain a concept only when the current step needs it, and keep it short and concrete, tied to
  this system (e.g. "Order would charge the card for seats that were never held").
- When code or structure is needed, say what to create and let the user write it. Then read the
  file yourself and check it. For small mechanical issues (typos, a missing semicolon, naming
  conventions), just say what to fix. For design issues, give a hint or a "what happens if..."
  question first. If the user says they don't understand, explain plainly and give the answer.
  Don't keep hinting.
- Never refer to decisions by their log number (D6, D7...) without saying what they mean. The
  user was confused by this. Use plain words.
- When the user asks you to do something small (like Makefile tweaks), just do it.
- Record each newly agreed decision in `DECISIONS.md` with a **Check:** line, because the user
  wants their implementation reviewed against it later.
- Git: commit with the user's default git identity. Never override user.name, and never add a
  Claude co-author or attribution line. Only commit or push when asked.

**Concepts the user has now learned:** idempotency keys per operation (not per caller), DB
constraints rather than app-level checks for races, statuses versus gRPC errors and retry rules,
UNSPECIFIED zero values, sagas and compensations (orchestration versus choreography), idempotent
compensations judged by end state, facts versus instructions in statuses, single source of
truth in requests, and money as int64 minor units.

## 10. Decisions log

Decisions agreed during the build are in `DECISIONS.md` in this folder (D1 to D11 so far: module
layout, Hold idempotency, the DB constraint for races, statuses versus errors, no version suffix,
UNSPECIFIED zero values, expires_at and no hold_id, ConfirmStatus EXPIRED, idempotent Confirm,
Release rules, and the Payment contract). Review the implementation against its **Check:** lines.

## 11. How to resume

When the user says "continue": re-ask the open question about the fields `OrderConfirmed` needs
(see section 8, "In progress"), in one short message. Don't recap everything.
