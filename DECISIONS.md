# Decisions log

Agreed design decisions, recorded as we make them. Each one has a **Check:** line, which is
what to verify in the implementation during review.

## D1. One Go module per service, joined with go.work (2 Nov 2026)
Modules: proto, order, tickets, payment, email. Services share contracts (proto) and nothing
else: no shared models or common package.
**Why:** a separate module makes importing another service's internals a compile error.
**Check:** no service imports another service's module; the only shared import is `proto`.

## D2. Hold is idempotent on order_id (3 Nov 2026)
HoldRequest carries `order_id`. Order generates it by inserting the PENDING order row before
calling Hold. The key identifies the operation, not the caller (not client_id or session_id).
**Why:** a lost response plus a retry would otherwise hold seats twice. A key per caller
would block a legitimate second purchase.
**Check:** HoldRequest has order_id. Order writes the PENDING row before calling Hold. Every
retry of that order reuses the same order_id.

## D3. Concurrent duplicates are stopped by a DB constraint, not an app-level check (3 Nov 2026)
`holds.order_id` is UNIQUE. Use `INSERT ... ON CONFLICT (order_id) DO NOTHING`. If 0 rows
are inserted, read and return the existing hold. The stock decrement and the hold insert run
in one transaction, so the losing request does not decrement stock.
**Why:** check-then-insert is a race; only the database can make it atomic.
**Check:** UNIQUE constraint exists. There is no SELECT-then-INSERT. The decrement and the
insert are in the same tx. A duplicate returns the original hold.

## D4. Business outcomes are response statuses; gRPC errors mean the call failed (3 Nov 2026)
Sold out is `status = SOLD_OUT` in a successful HoldResponse, not RESOURCE_EXHAUSTED. Apply
the same rule to Payment (a declined card is a status, not an error).
**Why:** it gives Order one simple retry rule: errors may be retried, statuses never are.
Retrying on sold out during a drop would hammer Tickets.
**Check:** the status enum has an UNSPECIFIED zero value. Order retries only on transient
gRPC codes (UNAVAILABLE, DEADLINE_EXCEEDED) and never on a status.

## D5. No version suffix in proto packages (3 Nov 2026)
Use `proto/tickets/tickets.proto` with `package tickets;`, not `tickets/v1`.
**Why:** the user chose not to practise API versioning in this project, so the suffix is noise.
**Check:** if buf is added later, disable the PACKAGE_VERSION_SUFFIX lint rule.

## D6. Enum zero value is UNSPECIFIED (3 Nov 2026)
Every enum starts with `X_UNSPECIFIED = 0`. Order treats UNSPECIFIED as an error.
**Why:** in proto3, an unset field reads as 0. If 0 meant SUCCESS, a buggy empty response
would make Order charge for seats that were never held.
**Check:** every enum has UNSPECIFIED = 0. Order's handling of the status has an explicit
branch for UNSPECIFIED and unknown values, and that branch fails closed.

## D7. Hold returns expires_at; holds are identified by order_id (3 Nov 2026)
HoldResponse has `google.protobuf.Timestamp expires_at`. There is no hold_id: Confirm and
Release take order_id, because each order has exactly one hold (D3).
**Why:** Tickets owns the expiry, so Order must not hard-code 10 minutes. Order uses the
deadline to avoid charging when the hold is about to expire.
**Check:** Order reads expires_at from the response, has no hard-coded TTL, and checks the
remaining time before calling Charge.

## D8. Confirm returns its own ConfirmStatus, with EXPIRED; Order refunds on EXPIRED (3 Nov 2026)
Confirm uses a separate enum (UNSPECIFIED / SUCCESS / EXPIRED, etc.) and does not reuse
HoldStatus. If Confirm returns EXPIRED after a successful Charge, Order calls Payment.Refund
and marks the order FAILED.
**Why:** each RPC answers its own question. "Expired" (Order was too slow) and "exhausted"
(sold out) mean different things and lead to different actions and diagnoses.
**Check:** ConfirmStatus is separate from HoldStatus. Order's EXPIRED branch calls Refund and
does not retry Confirm.

## D9. Confirm is idempotent: a retry of an already-confirmed hold returns SUCCESS (4 Nov 2026)
Confirming does not delete the hold. It changes holds.status from HELD to CONFIRMED. If
Confirm runs again for an order whose hold is already CONFIRMED, it returns SUCCESS and
changes nothing. An unknown order_id is a gRPC NOT_FOUND error (a bug), not a status.
ConfirmRequest contains only order_id (no event_id, so there is one source of truth).
Statuses describe facts in Tickets' own domain (EXPIRED), never caller actions (REFUND).
**Why:** after a lost response, a retry that returned "no hold" would make Order refund a
buyer who actually got their tickets.
**Check:** holds has a status column (HELD/CONFIRMED). Confirm on CONFIRMED returns SUCCESS
without side effects. There is no DELETE on confirm. Unknown order_id returns NOT_FOUND.

## D10. Release is idempotent and never releases a confirmed sale (4 Nov 2026)
Release(order_id): if the hold is HELD, return seats to stock and return success. If it is
already released or expired, return success and change nothing. If it is CONFIRMED, return
FAILED_PRECONDITION and change nothing. If the order_id is unknown, return NOT_FOUND.
ReleaseResponse is an empty message, so there is no status enum.
**Why:** compensations get retried, and success is judged by the end state the caller wants.
A CONFIRMED hold means the buyer paid, so releasing it would lose a paid order and allow an
oversell. When something unexpected happens, choose the recoverable outcome.
**Check:** release + stock increment happen in one tx and only from HELD. A second Release
does not increment stock again. There is a test for Release on CONFIRMED (returns an error
and stock is unchanged).

## D11. Payment contract: Charge with status; Refund idempotent with no status (6 Nov 2026)
ChargeRequest: order_id (idempotency key), int64 amount_minor + currency (never float), and
payment_token (never raw card details). ChargeResponse: ChargeStatus (UNSPECIFIED / SUCCESS /
DECLINED). There is no charge_id, because one order has one charge.
RefundRequest is order_id only (no amount, so there is one source of truth). RefundResponse is
empty. Refund on a charged order refunds it and returns success. On an already-refunded order
it returns success and does nothing. On a declined order it returns FAILED_PRECONDITION. On an
unknown order_id it returns NOT_FOUND. "Refund failed" is always a gRPC error, never a status.
**Why:** Order never retries statuses. A "refund failed" status would mean the buyer is never
refunded. Compensations must eventually succeed.
**Check:** charges.order_id is UNIQUE. A retried Charge returns the original result without
charging twice. Refund is a single state change from CHARGED to REFUNDED. Order retries Refund
on transient errors until it succeeds.
