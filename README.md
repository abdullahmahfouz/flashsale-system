# Flash-Sale Checkout

A flash sale puts many buyers in front of a small, fixed amount of stock at the same moment. The checkout must never oversell (more paid orders than stock) and must never double-charge (the same purchase retried by a client or a network layer must create only one order). This project is a small Rails API backed by Postgres that implements checkout three ways (`naive`, `locked`, `idempotent`), selectable at runtime, so the failure of the naive version and the fixes can be compared with concurrent tests and k6 load tests. The source of truth for behavior is [SPEC.md](SPEC.md).

## Architecture

```mermaid
flowchart LR
    C["k6 / curl client"] -->|"POST /checkout<br/>GET /products/:id"| R["Rails API (Puma)"]
    R -->|"CHECKOUT_MODE = naive | locked | idempotent<br/>(read on every request)"| P[("Postgres<br/>products, orders")]
```

Only the pieces above are on the request path. Redis and Sidekiq are NOT used by the checkout path yet: Redis runs as a service in `docker-compose.yml` and `sidekiq` is listed in the `Gemfile`, but nothing in `app/`, `config/` or `lib/` references either of them. They are not part of the working system.

Endpoints (and no others besides the Rails `/up` health check):

- `POST /checkout` with header `Idempotency-Key` and params `product_id`, `user_id`, `quantity`.
- `GET /products/:id` returns `id`, `name` and current `stock`.

### Schema summary

From `SPEC.md` and `db/schema.rb`:

- `products`: `id`, `name` (NOT NULL), `stock` (integer, NOT NULL) with the database constraint `CHECK (stock >= 0)` (named `products_stock_non_negative`).
- `orders`: `id`, `product_id` (NOT NULL, foreign key to `products`), `user_id` (NOT NULL), `quantity` (NOT NULL), `status` (NOT NULL, e.g. `paid`), `idempotency_key` (NOT NULL) with a UNIQUE index (`index_orders_on_idempotency_key`), `created_at` (NOT NULL).

## The three approaches

The mode is chosen with the `CHECKOUT_MODE` environment variable and is read on every request, not cached at boot. Any other value, including unset, returns 501 with an error body.

Invariants (SPEC.md):

1. Paid orders <= starting stock.
2. Stock is never negative.
3. Starting stock - stock left = paid orders.
4. One order per idempotency key.

Input validation applies to all modes: the `Idempotency-Key` header must be present, `product_id` and `user_id` must be positive integers, and `quantity` must be exactly `1` (0, negative, greater than 1 or non-integer values return 422). Because every order costs exactly one unit, invariant 3 counts orders and units identically.

### naive

Reads the product, checks `stock > 0`, writes `stock - 1` with `update_columns`, then creates the order. There is no transaction and no lock. Two requests can both read the same stock value and both proceed, so under concurrency it can create more orders than stock and lose decrements; that is the deliberate demonstration. Note that the `CHECK (stock >= 0)` constraint alone does not prevent this, because the naive code writes an absolute value computed from a stale read. It has no idempotency handling: a repeated key hits the unique index and the request fails (an unhandled error, not a clean status code).

### locked

Wraps the work in a transaction and loads the product with `Product.lock` (`SELECT ... FOR UPDATE`), then checks stock, decrements it and creates the order. Concurrent checkouts for the same product serialize on the row lock, so the check and the decrement are atomic with respect to each other and invariants 1 to 3 hold. Sold out returns 409. It has no key handling, but it does not crash on a duplicate key: the unique index raises, the transaction rolls back (stock unchanged), and the response is 409 with error `duplicate Idempotency-Key`. A client retry therefore does not double-charge, but it also does not get the original order back.

### idempotent

`locked` plus key handling:

- If an order with the key already exists, it is returned with 200 (checked before taking the lock, and again after acquiring the lock, so a duplicate that waited on the row lock sees the winner's order before anything is decremented).
- If a concurrent request with the same key hits `ActiveRecord::RecordNotUnique`, the transaction rolls back (stock decrement included) and the existing order is returned with 200.
- A replayed key whose payload (`product_id`, `user_id`, `quantity`) differs from the stored order returns 422 and writes nothing. This also applies on the `RecordNotUnique` race path.

### Status codes for `POST /checkout`

| status | meaning |
| --- | --- |
| 201 | order created |
| 200 | idempotent mode only: duplicate key with the same payload; the original order is returned |
| 409 | sold out; in locked mode also a duplicate key (error `duplicate Idempotency-Key`) |
| 422 | invalid input (missing key, bad `product_id`/`user_id`, `quantity` not 1), unknown `product_id`, or in idempotent mode a replayed key with a different payload |
| 501 | `CHECKOUT_MODE` is not `naive`, `locked` or `idempotent` |

## Results

Source: [loadtest/results.md](loadtest/results.md). The setup note and table below are copied from that file.

Setup: laptop, single Puma process (WEB_CONCURRENCY=0, RAILS_MAX_THREADS=16, DB_POOL=100), Rails in
`production` env (logs at warn level to a file), Postgres 16 and Redis in Docker, k6 on the same machine.
Puma on one laptop is the bottleneck, so absolute numbers are only comparable across modes in this setup.
Dedicated DB `flashsale_system_loadtest`; every run deletes all orders and resets product 1 stock to the
starting stock (default 1000). Latencies are http_req_duration in ms. Error rate is http_req_failed
(5xx, 422, network failures; 201/200/409 are treated as expected). "oversold" = max(0, paid - starting stock).

| date | mode | scenario | start stock | p50 ms | p95 ms | p99 ms | req/s | error rate | 201 | 200 | 409 | other | orders in DB | stock left | oversold | invariants |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-09 14:59:32 | naive | spike | 1000 | 266.6 | 798.27 | 889.06 | 1590.46 | 0 | 2707 | 0 | 29522 | 0 | 2707 | 0 | 1707 | 1 FAIL, 2 PASS, 3 FAIL, 4 PASS |
| 2026-11-09 15:00:30 | locked | spike | 1000 | 428.2 | 734.86 | 1334.35 | 1059.93 | 0 | 1000 | 0 | 20637 | 0 | 1000 | 0 | 0 | 1 PASS, 2 PASS, 3 PASS, 4 PASS |
| 2026-11-09 15:01:20 | idempotent | spike | 1000 | 548.96 | 987.05 | 1297.09 | 840 | 0 | 1000 | 0 | 16229 | 0 | 1000 | 0 | 0 | 1 PASS, 2 PASS, 3 PASS, 4 PASS |
| 2026-11-09 15:02:17 | naive | retry-storm | 1000 | 105.07 | 139.08 | 462.66 | 1653.6 | 0.041813314081159944 | 1 | 0 | 31852 | 1390 | 1 | 0 | 0 | 1 PASS, 2 PASS, 3 FAIL, 4 PASS |
| 2026-11-09 15:02:41 | locked | retry-storm | 1000 | 502.29 | 522.58 | 527.18 | 396.93 | 0 | 1 | 0 | 8133 | 0 | 1 | 999 | 0 | 1 PASS, 2 PASS, 3 PASS, 4 PASS |
| 2026-11-09 15:03:06 | idempotent | retry-storm | 1000 | 117.77 | 121.26 | 124.13 | 1686.6 | 0 | 1 | 33924 | 0 | 0 | 1 | 999 | 0 | 1 PASS, 2 PASS, 3 PASS, 4 PASS |

### How to read this

- Naive, spike: the table shows a nonzero `oversold` value and invariants 1 and 3 failing, i.e. more orders were created than there was stock.
- Locked and idempotent, spike: `oversold` is 0, orders in DB equal the starting stock, and all four invariants PASS.
- Naive, retry-storm: the table shows 1 order in the database but stock left of 0, so invariant 3 fails (a single order should have left 999). Locked and idempotent leave 999 in stock and pass all invariants.
- Retry-storm, locked vs idempotent: both create 1 order. Locked answers the repeated key with 409 (the 409 column), idempotent answers with 200 (the 200 column).
- Naive retry-storm is the only row with a nonzero error rate and a nonzero `other` count.

Caveats:

- Everything ran on one laptop with a single Puma process, with k6 on the same machine, so k6 and the server compete for the same CPU.
- Each cell is one 20 s run, not repeated; treat differences between rows as indicative, not statistically established.
- Latencies are not like-for-like across modes, because the response mix differs between modes (for example, 201s, 200s and 409s have different costs, and the naive spike creates more orders).
- Absolute numbers are only comparable across modes within this setup.
- The `ramp` scenario exists in `loadtest/` but has no rows in `results.md`, so it is not reported here.

## Running it

Commands in this section were written from reading the repository (`config/database.yml`, `docker-compose.yml`, `loadtest/run.sh`, `test/`); they have not all been executed as a fresh-clone walkthrough.

### Prerequisites

- Ruby 3.3.5 (`.ruby-version`) and Bundler
- Docker with Docker Compose
- `psql` (used by the load test scripts)
- [k6](https://k6.io/) and `jq` (used by `loadtest/run.sh`), plus `curl` and `lsof`

### Setup

```sh
git clone <this repository> flashsale-system
cd flashsale-system
bundle install
docker compose up -d
```

`docker compose up -d` starts Postgres 16 (host port 5433, user `postgres`, password `postgres`, started with `max_connections=300`) and Redis 7 (host port 6380). Redis is not used by the checkout path. The ports are 5433 and 6380 so they do not clash with a local Postgres or Redis.

`config/database.yml` does not set a host or credentials, so point Rails at the compose Postgres with `DATABASE_URL`:

```sh
export DATABASE_URL=postgres://postgres:postgres@localhost:5433/flashsale_system_development
bin/rails db:create db:migrate db:seed
```

The seed creates one product, "Flash Sale Item", with stock 100 (from `db/seeds.rb`).

### Start the server

```sh
CHECKOUT_MODE=idempotent DB_POOL=25 bin/rails server
```

Use `naive`, `locked` or `idempotent` for `CHECKOUT_MODE`. `DB_POOL` sets the Active Record pool size (default 25 in `config/database.yml`).

### Example requests

```sh
curl http://localhost:3000/products/1

curl -i -X POST http://localhost:3000/checkout \
  -H "Idempotency-Key: order-abc-123" \
  -H "Content-Type: application/json" \
  -d '{"product_id": 1, "user_id": 42, "quantity": 1}'
```

Repeating the same POST in `idempotent` mode returns 200 with the original order; in `locked` mode it returns 409 with `duplicate Idempotency-Key`.

### Tests

The tests (`test/integration/*`, Minitest) are non-transactional, use real threads, and share one test database, so they need a separate database, a large connection pool, and an explicit mode:

```sh
export TEST_DATABASE_URL=postgres://postgres:postgres@localhost:5433/flashsale_system_test
RAILS_ENV=test DATABASE_URL=$TEST_DATABASE_URL bin/rails db:create db:schema:load
RAILS_ENV=test DATABASE_URL=$TEST_DATABASE_URL DB_POOL=250 CHECKOUT_MODE=idempotent bin/rails test
```

Run the suite once per mode by changing `CHECKOUT_MODE`. The test helper fails tests if `CHECKOUT_MODE` is not one of the three modes. `DB_POOL=250` keeps the connection pool from being the bottleneck for the 200-thread tests, which also relies on Postgres `max_connections=300` from the compose file.

Naive and locked are EXPECTED to fail the tests that only idempotent mode should pass: naive is expected to fail the oversell and invariant tests by design, and the idempotency tests (such as a same-key replay returning 200 with the original order) are documented in `test/integration/idempotency_test.rb` as expected to fail in naive (unique index error) and locked (409 duplicate key) because only idempotent mode implements key handling. Some tests are mode-specific or follow the current mode, so which tests fail under each mode depends on the test; check the comments in each test file. A failing run under `naive` or `locked` is therefore not a bug in the tests. The expected results per mode are described in comments at the top of each test file; this README does not state pass counts because none were run for it.

### Load tests

```sh
./loadtest/run.sh <naive|locked|idempotent> <spike|retry-storm|ramp>
```

Requirements, from reading `loadtest/run.sh`:

- Postgres from `docker compose` must be running, and a dedicated database must already exist with the schema loaded. By default it uses `postgres://postgres:postgres@localhost:5433/flashsale_system_loadtest`; override with `LOADTEST_DATABASE_URL`. The script does not create the database itself.
- `psql`, `k6`, `jq`, `curl` and `lsof` must be installed.
- Port 3000 (override with `PORT`) must be free. The script starts its own Rails server in `production` env, runs k6, then stops only the server it started.
- Each run deletes all orders, resets product 1 to `STARTING_STOCK` (default 1000), runs the invariant checks in `loadtest/check_invariants.sql`, and appends one row to `loadtest/results.md`. Raw output goes to `loadtest/out/` and `loadtest/logs/`.
- Other knobs: `RAILS_MAX_THREADS` (default 16), `DB_POOL` (default 100), `WEB_CONCURRENCY` (default 0).

One way to create the loadtest database (not verified by running it; adjust if your setup differs):

```sh
DATABASE_URL=postgres://postgres:postgres@localhost:5433/flashsale_system_loadtest bin/rails db:create db:schema:load
```

## Future work

None of the following is implemented.

- Redis `DECR` comparison: reserve stock with an atomic Redis decrement and compare it against the Postgres row lock for throughput and correctness.
- Reservation expiry: hold stock for a buyer for a limited time and release it if the order is not completed.
- Waiting room: queue incoming buyers and admit them at a controlled rate instead of letting every request hit the checkout at once.

## What broke and how I fixed it

> TODO: to be written by the author.
