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

- Language: assumed **Go** (user is a Go/PHP backend dev). Possibly one service in PHP to show language independence.
- Kubernetes vs ECS for the eventual deploy.
- Time budget per week (decides how far into the stretch goals to go).

## 8. Next step (to walk through next session)

Build the plain version locally, no fixes yet:
1. Repo layout: monorepo with `order/`, `tickets/`, `payment/`, `email/`, `proto/`, `docker-compose.yml`, `loadtest/`.
2. Write the `.proto` contracts first: Tickets (Hold, Confirm, Release) and Payment (Charge).
3. docker-compose: one Postgres container with a separate database + user per service, plus LocalStack for SNS/SQS.
4. Implement Tickets and Payment gRPC servers with their schemas.
5. Implement Order: HTTP `POST /orders`, calls Hold -> Charge -> Confirm, saves state. Publish directly to SNS at first (no outbox yet, so experiment 4 can show the bug).
6. Implement Email as an SQS long-polling consumer that logs the "email".
7. Happy-path test with curl, then start experiment 1.

## 9. How to guide the user

The user is an experienced backend developer (8+ years, Go/PHP). Don't hand-hold or explain basics
like Docker, SQL or HTTP. Do teach: for each step, explain the microservices-specific reasoning and
trade-offs, point out what will break and why, and let the user write the code. Prefer short
pointers, questions and "what do you think happens if..." over full solutions, unless asked.

## 10. Decisions log

Decisions agreed during the build are recorded in `DECISIONS.md` in this folder. Review the implementation against it.
