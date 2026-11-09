# Flash-Sale Checkout: SPEC

Rails (API mode) + Postgres + Redis + Sidekiq + k6. Postgres and Redis run in Docker Compose.
Goal: never oversell, never double-charge.

## Schema

### products
| column | type | constraints |
| --- | --- | --- |
| id | bigint | PK |
| name | string | NOT NULL |
| stock | integer | NOT NULL, DB `CHECK (stock >= 0)` |

### orders
| column | type | constraints |
| --- | --- | --- |
| id | bigint | PK |
| product_id | bigint | NOT NULL, FK -> products |
| user_id | bigint | NOT NULL |
| quantity | integer | NOT NULL |
| status | string | NOT NULL (e.g. `paid`) |
| idempotency_key | string | NOT NULL, **UNIQUE index** |
| created_at | datetime | NOT NULL |

## Endpoints

### POST /checkout
Header: `Idempotency-Key` (required). Body: `product_id`, `user_id`, `quantity`.

| status | meaning |
| --- | --- |
| 201 | order created |
| 200 | duplicate key; the original order is returned |
| 409 | sold out |
| 422 | invalid input (missing key, bad product_id/user_id/quantity, etc.) |

### GET /products/:id
Returns the product, including current `stock`.

No other endpoints.

## Invariants

1. Paid orders <= starting stock.
2. Stock is never negative.
3. Starting stock - stock left = paid orders.
4. One order per idempotency key.

## Checkout modes

Selected by the `CHECKOUT_MODE` env var (`naive`, `locked`, `idempotent`). It is read on **every request**, not cached at boot.

### naive
Read stock, check `> 0`, write `stock - 1`, create order. No transaction, no lock. Expected to violate the invariants under concurrency (that is the demonstration).

### locked
Wrap in a transaction and load the product with `Product.lock.find` (`SELECT ... FOR UPDATE`). Check stock, decrement, create order.

### idempotent
`locked` plus key handling:
- If an order with the given key already exists, return it with **200**.
- If a concurrent request with the same key hits `ActiveRecord::RecordNotUnique`, roll back (stock decrement included) and return the existing order with **200**.

## Clarifications (added after review)

- **Quantity:** `quantity` must be exactly `1`. Any other value (0, negative, > 1, non-integer) is **422**. Every mode decrements stock by 1 per order, so invariant 3 counts orders and units identically.
- **Unknown mode:** a `CHECKOUT_MODE` other than `naive`, `locked` or `idempotent` (including unset) returns **501** with an error body. 501 is part of the status table for `POST /checkout` for this case only.
- **Replayed key with a different payload (idempotent mode):** the payload is `product_id`, `user_id`, `quantity`. If an existing order for the key has the same payload, return it with **200**. If the payload differs, return **422** and write nothing. This also applies on the `RecordNotUnique` race path: roll back (stock decrement included), then return 200 with the existing order if the payload matches, or 422 if it does not.
- **Duplicate key in locked mode:** locked has no key handling, but it must not crash. A duplicate key returns **409** with error `duplicate Idempotency-Key`; the transaction rolls back and stock is unchanged. (A 409 caused by a duplicate key is distinguished from sold-out by its error body.)
- **Duplicate key in naive mode:** no handling; the unique index rejects the second order and the request fails. Naive is deliberately unsafe.
