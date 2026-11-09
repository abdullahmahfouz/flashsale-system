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
