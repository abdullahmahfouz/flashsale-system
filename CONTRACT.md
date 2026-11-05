# CONTRACT.md — shopkit (multi-tenant Rails 8 API, living in the flashsale-system repo)

Stack: Rails 8.1 API-only, MySQL (mysql2), Redis, Sidekiq, Sorbet, Packwerk.
The **Gemfile, config/application.rb, bin/, Dockerfile are frozen** (set up in Phase 0). No agent edits them.
No gems beyond: rails, mysql2, redis, sidekiq, sorbet, packwerk, test tooling. Do not invent features outside this file.

## Schema (final)
| table | columns |
|---|---|
| shops | id, name, api_token (unique) |
| products | id, shop_id, title, price_cents |
| orders | id, shop_id, status, total_cents |
| line_items | id, shop_id, order_id, product_id, quantity |
| webhook_events | id, shop_id, event_id (unique), payload, status |

Plus Rails `created_at`/`updated_at` on every table. `shop_id` is NOT NULL with an index and a foreign key on every tenant table.
Money is integer cents. `payload` is `json`. Defaults/enums (use exactly these strings):
- orders.status: `pending` (default) | `paid` | `cancelled`
- webhook_events.status: `received` (default) | `processing` | `processed` | `failed` | `dead`
`webhook_events.event_id` is globally unique (a unique index; it is what dedupes webhooks).

## Tenancy
- `Current.shop` (`app/models/current.rb`, an `ActiveSupport::CurrentAttributes`) is set once per request (API) or per job (jobs call `Current.set(shop: shop) { ... }`).
- Every tenant model (Product, Order, LineItem, WebhookEvent) includes `TenantScoped` (`app/models/concerns/tenant_scoped.rb`): `default_scope` filters `shop_id: Current.shop.id` and **raises `Current::ShopNotSet`** (a `StandardError` defined in `current.rb`) if `Current.shop` is nil. New records get `shop_id` from `Current.shop`.
- `Shop` is the only unscoped model (used for token lookup: `Shop.find_by(api_token: token)`).
- Cross-tenant access must look like "not found" (404), never 403.

## API
- Base path `/api/v1`. Auth: `Authorization: Bearer <shops.api_token>`.
- Resources: `products` (index, show, create, update) and `orders` (index, show, create with nested `line_items: [{product_id, quantity}]`; total_cents is computed server-side).
- JSON errors, always `{ "error": { "code": "<slug>", "message": "<text>" } }` (422 also has `"details": {field: [msgs]}`):
  - 401 `unauthorized` (missing/invalid token)
  - 404 `not_found`
  - 422 `unprocessable_entity`
- Webhook ingestion is a service/job, not an HTTP endpoint (no endpoint is specified here).

## Shared names (so agents can code against each other before merging)
- Models: `Shop`, `Product`, `Order`, `LineItem`, `WebhookEvent`, `Current`, concern `TenantScoped`.
- Services/jobs (jobs agent): `Webhooks::IngestOrderEvent.call(shop:, event_id:, payload:)`, `ProcessOrderEventJob`, `ProductListCache.fetch(shop)` / `.invalidate(shop)`.
- Webhook payload (minimal): `{ "type": "order.paid", "order_id": <id> }` -> marks that order `paid`.

## Local environment (agents run in parallel, so they must not share state)
Each agent exports before running anything: `DB_SUFFIX=_<agent>` (e.g. `_models`) and `REDIS_URL=redis://localhost:6379/<n>` with n: models=1, api=2, jobs=3, quality=4. `config/database.yml` honours `DB_SUFFIX`. MySQL is root with no password on 127.0.0.1.

## Directory ownership (no agent edits another's files)
| agent / branch | owns |
|---|---|
| models | `app/models/**`, `db/**`, `config/database.yml`, `test/models/**`, `test/test_helper.rb`, `test/support/**` |
| api | `app/controllers/**`, `config/routes.rb`, `test/controllers/**`, `test/integration/**` |
| jobs | `app/jobs/**`, `app/services/**`, `config/initializers/sidekiq.rb`, `config/initializers/redis.rb`, `test/jobs/**`, `test/services/**` |
| quality | `sorbet/**`, `packwerk.yml`, every `package.yml`, `.github/workflows/**`, `README.md` |

Quality never changes app code: it logs problems in PROGRESS.md. PROGRESS.md lives in each worktree root and is owned by that agent.
