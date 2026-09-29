# Cass

A unified marketplace for digital products, compliant social marketing
services, and AI-powered tools, built with Elixir, Phoenix LiveView, and
PostgreSQL.

**Status: Milestone 5 (transactional checkout with atomic stock
reservation).** This release ships the server-rendered storefront catalog, a
complete, session-based account system (registration with emailed confirmation,
login with an optional 14-day remembered session, password reset, and account
settings), a minimal role system where every account is a customer and
`:admin`/`:vendor` are explicit grants read from the database on each request,
product ownership: a product either belongs to the platform
(`owner_id IS NULL`) or to one account, with a protected `/manage/products`
area for sellers and admins, and the product-centric catalog: everything sold
is a `Product` with a closed product-type vocabulary
(`digital | smm | ai | service`) and per-variant pricing/stock
(`cass_product_variants`). A customer can now sign in, pick a variant and
quantity on a product page, and check out: `Cass.Orders` resolves, prices, and
reserves stock in one transaction, snapshots each line into `cass_order_items`,
and `/orders` lists the purchase. Payment capture, transfers, and AI features
arrive in later milestones and are **not** available yet.

## Requirements

* Elixir `~> 1.17` and OTP `27`
* PostgreSQL 18
* Node.js (for the Tailwind and esbuild binaries)

## Getting started

```bash
mix setup          # install deps, create/migrate DB, build assets
mix phx.server     # start the server (http://localhost:4000)
```

Useful commands:

```bash
# Run the full quality gate (format, compile with warnings as errors, tests)
mix precommit

# Run only tests
mix test

# Bootstrap the first admin (the only way to obtain a role)
CASS_ADMIN_PASSWORD='...' mix cass.accounts.create_admin --email you@example.com
```

## What's implemented

### Accounts and authentication (Milestone 3 Phase 1)

* **Accounts context** — `Cass.Accounts` owns `cass_users` and
  `cass_users_tokens`: registration, credential lookup, email confirmation,
  revocable session tokens, email changes, and password resets. Passwords are
  hashed with PBKDF2-HMAC-SHA512 and every one-time link is stored as a SHA-256
  hash, bound to the address it was mailed to, single-use, and expiring. See
  [docs/data-model.md](docs/data-model.md).
* **Pages** — server-rendered LiveViews with a shared auth card:
  * `/users/register` — create an account (confirmation link emailed)
  * `/users/log-in` — sign in, with an optional "stay signed in for 14 days"
  * `/users/reset-password` — request a reset link (identical answer for
    unknown addresses)
  * `/users/reset-password/:token` — choose a new password
  * `/users/settings` — change email (confirmed at the new address first) and
    password (revokes every other session)
* **Sessions** — a revocable token in a signed, HttpOnly, `SameSite=Lax` cookie
  (`secure` in production), reissued weekly, plus a signed 14-day remember-me
  cookie. Logout revokes server-side and disconnects open LiveViews. See
  [docs/security.md](docs/security.md).
* **Single seam** — `CassWeb.UserAuth` provides the browser pipeline plug, the
  LiveView `on_mount` hooks, and the `current_scope` assign that every page
  reads. `Cass.Accounts.Scope` carries the user and their roles.
* **No email provider is wired up yet** — Swoosh delivers to the local mailbox
  at `/dev/mailbox` in development, so confirmation and reset links are read
  there.

### Roles and authorization (Milestone 3 Phase 2)

* **Closed vocabulary** — `:admin` and `:vendor`, owned by
  `Cass.Accounts.UserRole.roles/0` and enforced again by a database CHECK
  constraint. There is no `:customer` role: holding no role *is* being a
  customer, so being signed in never implies a privilege.
* **`cass_user_roles` join table** — an account can hold several roles; a unique
  `[user_id, role]` index makes granting idempotent, and deleting an account
  deletes its roles. See [docs/data-model.md](docs/data-model.md).
* **Resolved server-side on every request** — `Cass.Accounts.Scope.for_user/1`
  reads the roles from the database each time a scope is built, so a grant
  applies on the next request and a **revoke applies on the next one** — there
  is no role in the session or cookie to go stale.
* **No escalation path** — no route grants a role, no login or query parameter
  can name one, `user_id` is never cast, untrusted role strings are matched
  against a fixed table (no `String.to_atom/1`), and a role outside the
  vocabulary is rejected by both the changeset and the database. See
  [docs/security.md](docs/security.md).
* **Guards** — `require_admin_user/2` / `on_mount(:require_admin)` and
  `require_vendor_user/2` / `on_mount(:require_vendor)` sit next to the existing
  `require_authenticated_user` seam, with `Scope.admin?/1` and `Scope.vendor?/1`
  as the single source of truth. An admin is **not** implicitly a vendor.
* **Bootstrap only** — `mix cass.accounts.create_admin` requires an explicit
  email, takes the password from `--password`/`CASS_ADMIN_PASSWORD`, refuses to
  run in production without `--force`, and is safe to re-run. The first account
  to register is never auto-promoted.
* **Not yet exposed** — no admin dashboard, vendor onboarding, or
  role-management UI; the guards are in place for the phases that will use
  them, and nothing is half-protected in the meantime.

### Product ownership (Milestone 3 Phase 3)

* **Nullable owner, no fake owners** — `cass_products.owner_id` references
  `cass_users.id` and is nullable; `NULL` means the product belongs to CASS
  itself. No system account, no placeholder user, and no backfill: the existing
  products simply stay platform-owned.
* **`ON DELETE RESTRICT`, indexed, not unique** — one account may own many
  products, and the database refuses to delete an account that still owns one,
  so a future `delete_user/1` cannot silently orphan or cascade a catalog.
  See [docs/data-model.md](docs/data-model.md).
* **Ownership is data, not a capability** — it is a fact about a product and is
  independent of the roles that grant the ability to act on it. A vendor owns
  and manages their own products; an admin owns products and manages anyone's;
  a customer or guest can do neither; and a platform product is admin-only,
  because it has no owner to match.
* **Authorization lives in the context** — `create_owned_product/3`,
  `update_product/3`, `publish_product/2`, and `archive_product/2` all take the
  caller's `Cass.Accounts.Scope` as their first argument and check
  `can_create_owned_product?/1` or `can_manage_product?/2` before touching a
  row, so a caller reaching the context directly cannot skip the check.
  See [docs/security.md](docs/security.md).
* **Ownership is never read from the client** — `owner_id` is absent from the
  product changeset's cast list and `create_owned_product/3` writes
  `scope.user.id` itself, so a submitted `owner_id` is ignored rather than
  obeyed. There is no transfer API or UI, so ownership cannot change after
  creation by any means.
* **Reads are scoped, and refusals are not enumerable** —
  `list_managed_products/1` and `get_managed_product/2` filter by the caller's
  rights in SQL and return `nil` for anything else, so a guessed product id is
  indistinguishable from one that does not exist. The unfiltered
  `get_product!/1` getter was removed for the same reason.
* **A small protected surface** — `/manage/products` (list, publish, archive),
  `/manage/products/new`, and `/manage/products/:id/edit`, behind
  `require_vendor_or_admin_user` and the matching `on_mount` hook, with
  `noindex` metadata. It is a boundary proof, not a seller dashboard: no
  pricing, orders, payouts, or onboarding.
* **Public behavior is unchanged** — the storefront, its queries, URLs, SEO,
  and JSON-LD are untouched, and no owner information is rendered or exposed
  publicly.

### Product-centric catalog (Milestone 4)

* **Everything sold is a Product** — `Cass.Catalog.Product` now carries the
  closed product-type vocabulary (`product_types/0` → `:digital`, `:smm`,
  `:ai`, `:service`), enforced again by a database CHECK constraint, and a
  `featured` showcase flag. The former `digital_product`/`smm_service`/`ai_tool`
  values were renamed in a deterministic data migration without losing any
  existing rows. See [docs/data-model.md](docs/data-model.md).
* **Product Variants own pricing and stock** — `cass_product_variants`
  (`price_cents` integer minor units, `currency` default `USD`, nullable
  `stock` = unlimited, `active`, `sort_order`, type-specific `config` JSONB
  with string keys only). A variant is `purchasable?` when active and in
  stock; names are unique per product (case-insensitive) and `sku` globally
  unique.
* **Scope-first variant authorization** — `create_variant/3` and
  `update_variant/3` take the caller's scope first and reuse
  `can_manage_product?/2`, and `product_id` is never taken from params. See
  [docs/security.md](docs/security.md).
* **Fulfillment boundary** — `Cass.Fulfillment.kind_for/1` maps a product type
  to a fulfillment kind (`digital`/`smm`/`ai`/`manual`), a seam for future
  checkout code; no fulfillment table or provider integration exists yet.
* **Public storefront unchanged** — product/category pages, slugs, SEO, and
  JSON-LD keep working; product pages may now preload `active_variants`.

### Checkout foundation (Milestone 5)

* **`Cass.Orders` is the checkout boundary** — `create_order/2` takes the
  caller's scope and minimal `product_variant_id` + `quantity` lines, and does
  everything in one `Repo.transact` (the `accounts.ex` `{:ok, _}/{:error, _}`
  convention): resolve variants, verify sale eligibility, **atomically reserve
  stock**, insert the order and its snapshot items. Any refusal rolls
  everything back. See [docs/data-model.md](docs/data-model.md).
* **Money is server-derived** — the variant row is the only authority on price
  and currency. Line totals (`unit_price_cents * quantity`) and the order
  `total_cents` (the server sum, stored) are computed in the transaction; a
  request carrying its own price/total/currency/ownership is ignored
  field-by-field. Orders are single-currency, refused wholesale otherwise.
* **Stock cannot oversell** — reservation is one conditional statement
  (`UPDATE ... SET stock = stock - qty WHERE id = ? AND active AND stock IS
  NOT NULL AND stock >= qty`, `nil` = unlimited), so concurrent buyers
  claiming the last units serialize on the row lock
  (`test/cass/orders_concurrency_test.exs` proves exactly N sold, stock
  never negative). DB CHECK constraints (`stock/price_cents >= 0`) back it up.
* **Order items are historical snapshots** — product/variant name, SKU, unit
  price, currency, quantity, and `metadata` (the variant `config`) are copied
  at checkout and never re-derived; both FKs are `on_delete: :restrict` so
  catalog edits or account deletion can't rewrite or destroy a receipt.
* **Lifecycle vocabulary** — `awaiting_payment` (created, stock reserved) →
  `paid` → `processing` → `completed`, terminal `cancelled`/`failed`, mirrored
  by a CHECK constraint; only creation is reachable until the Payments
  milestone.
* **Minimal web surface** — signed-in shoppers get a variant + quantity buy
  form on product pages (`POST /orders`), guest shoppers a sign-in prompt;
  `/orders` and `/orders/:id` show a customer's own orders (admin sees all;
  anything else renders not-found). No payment capture, no vendor side of
  orders, no fulfillment beyond the `Cass.Fulfillment` seam.

### Catalog (Milestone 2)

* **Catalog domain** — `categories` and `products` tables (migrations in
  `priv/repo/migrations`), Ecto schemas, and the `Cass.Catalog` context with
  create/update/publish/archive operations and public read queries.
  See [docs/data-model.md](docs/data-model.md).
* **Public catalog pages** — server-rendered LiveViews with full SEO metadata:
  * `/catalog` — categories and latest products
  * `/catalog/categories/:slug` — category page (breadcrumb, children)
  * `/catalog/products/:slug` — product page (details, category link)
  Unknown/restricted slugs render a not-found state with `noindex`.
* **Data integrity rules** — globally unique slugs, sibling-unique category
  names, immutable published/archived slugs, archived-entity immutability,
  publish gating (`:draft` + active category), and visibility
  (`public`/`unlisted`/`private`) with `published_at` scheduling.
* **Seeds** — `mix run priv/repo/seeds.exs` loads four root categories with
  a published product each (idempotent), including a `:service` "Manual SEO
  Audit" product.
* **Health endpoint** — `GET /api/v1/health` reports service, version,
  environment, database status, uptime, and a timestamp. See
  [API contract](docs/api-contract.md).
* **Documentation** — architecture, API contract, data model, security, and
  deployment notes under [`docs/`](docs/).
* **CI** — formatting, compile-as-warnings-as-errors, and full test suite run
  on every push via GitHub Actions (`.github/workflows/ci.yml`).

## Project layout

See [docs/architecture.md](docs/architecture.md) for details.

* `lib/cass` — application contexts and business logic
* `lib/cass_web` — web layer (controllers, LiveViews, components)
* `config/` — environment configuration
* `docs/` — architecture and roadmap documentation
* `test/` — ExUnit tests

## Roadmap (short term)

1. ~~Catalog domains (products, categories) with Ecto schemas and migrations~~
2. ~~Storefront catalog pages~~
3. ~~Accounts and authentication~~
4. ~~Roles and authorization foundation (`:admin`/`:vendor`, guards)~~
5. ~~Product ownership and ownership-safe management~~
6. ~~Product-centric catalog (product types + variants; `:service` type)~~
7. Vendor onboarding, admin dashboard, profile, and account deletion
   (ownership *transfer* is deliberately deferred: deleting an account that
   still owns products is refused by the database)
8. ~~Checkout and order flow (order items consume variant pricing/stock)~~
9. Payments and fulfillment (capture `awaiting_payment` orders, drive the
   lifecycle, hand off to `Cass.Fulfillment.kind_for/1`)
10. AI tools routed through the Nexus AI Gateway
11. JSON catalog API under `/api/v1` (optional, additive)

Payments, physical product fulfillment, and live AI integrations are scoped to
later milestones.

## Learn more

* Phoenix: https://www.phoenixframework.org/
* LiveView: https://hexdocs.pm/phoenix_live_view/
* Ecto: https://hexdocs.pm/ecto/
* Tailwind CSS v4: https://tailwindcss.com/