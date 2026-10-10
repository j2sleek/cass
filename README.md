# Cass

A unified marketplace for digital products, compliant social marketing
services, and AI-powered tools, built with Elixir, Phoenix LiveView, and
PostgreSQL.

**Status: Milestone 9 (sellers and the account lifecycle).**
This release ships the server-rendered storefront catalog, a
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
and `/orders` lists the purchase. Payment capture works end to end through
Paystack (hosted checkout), and a captured order now **owes deliveries**:
`Cass.Fulfillment` turns each paid line into a tracked delivery
(`cass_fulfillments`) and `Cass.Entitlements` grants the buyer a durable,
snapshotted entitlement (`cass_entitlements`) when that delivery completes. A
completed digital purchase is now **exercisable**: `Cass.Delivery` answers *how*
the right is used, separately from the entitlement that proves it, and
`/purchases/:id` shows the buyer their access code, reachable from their own
order page. An account can now **become a seller**: `/sell` writes an onboarding
application (a `cass_vendor_profiles` row), an admin approves or rejects it on
`/admin/vendors` — approval is the one place that grants the `:vendor` role —
and an approved seller's display name replaces the email-derived handle on the
products they sell. Settings now manages **sessions** (list, revoke one, sign
out everywhere) and offers **account deletion**, which is a soft,
receipt-preserving deactivation that is refused while the account still owns a
product. SMM/AI/manual delivery, real download infrastructure, vendor
transfers/settlements, and AI features arrive in later milestones and are
**not** available yet.

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

### Payments and capture (Milestone 6)

* **`Cass.Payments` is the payments boundary** — payment rows snapshot the
  order's money (`amount_cents`/`currency` from the order total), name the
  `provider`, `provider_reference` (CASS-generated, e.g. `PY-…`), checkout URL,
  and `metadata`; statuses `pending/processing/succeeded/failed/cancelled`
  (`expired`/`refunded` reserved) with a partial unique index on
  `(provider, provider_reference)`.
* **Provider-agnostic by design** — `Cass.Payments.Provider` behaviour +
  `Cass.Payments.Providers` config-driven registry
  (`config :cass, Cass.Payments, providers:`); disabled/unknown providers
  resolve to `{:error, :unknown_provider}`. Adapters (`Paystack` first) are
  thin, stateless HTTP clients (`Req`, bearer auth) producing
  `InitResult`/`CaptureResult` structs and never touch orders, users, or the DB.
* **Idempotent from both directions** — re-initializing a live attempt returns
  the same checkout URL without recontacting the provider; a provider failure
  records `:failed` + reason and lets a retry start fresh. A duplicate *success*
  webhook is a committed no-op, so nothing is ever paid twice; a captured
  amount/currency that doesn't match the snapshot is refused outright.
* **Webhooks are signed, not session-auth'd** — `POST /webhooks/paystack`
  sits outside `:browser`; a custom body reader hands the controller the exact
  bytes and the adapter HMAC-SHA512-verifies `x-paystack-signature` against
  them. Bad signatures get a terse 400, unknown refs a 404, success a 200 ack.
* **Success pays payment + order in one `Repo.transact`** —
  payment → `:succeeded` (+`paid_at`) and `Orders.mark_order_paid/1`
  (`:awaiting_payment → :paid`, idempotent) commit or roll back together; no
  DB transaction ever waits on a call to the provider. Reported failure only
  deflates the payment to `:failed`/`:cancelled`, leaving the order retryable.
* **Owner-only pay surface** — `POST /orders/:id/pay` authorizes by scope,
  redirects to the hosted Paystack checkout, and refuses everything else with
  non-enumerable generic messages; `OrdersLive` shows the pay form (server total
  on the button) only for the owner of an awaiting-payment order.

### Fulfillment and entitlements (Milestone 7)

* **The chain is one-directional, and every arrow is a foreign key** —
  `paid order → order item → fulfillment → entitlement`. A fulfillment says
  *how* a purchase is delivered; an entitlement says the purchase succeeded and
  the buyer may use it. Keeping them apart is what lets a delivery be retried,
  re-routed, or handed to a human without touching the grant. See
  [docs/data-model.md](docs/data-model.md).
* **One delivery per purchased line** — `Cass.Fulfillment` turns each line of a
  paid order into a `cass_fulfillments` row with a stored `kind`
  (`:digital | :smm | :ai | :manual`, resolved once from the purchased product
  type by the single `kind_for/1` mapping) and an explicit lifecycle:
  `pending → processing → fulfilled`, `pending|processing → failed|cancelled`,
  `failed → processing|cancelled`, with `fulfilled`/`cancelled` terminal. An
  order mixing a digital product and a service gets a `:digital` and a
  `:manual` delivery, each tracked separately.
* **The paid order is the only authority** —
  `create_for_paid_order/1` asks `Orders.get_paid_order/1`, not its own
  judgment, and re-reads the stored row even when handed a struct, so a stale or
  forged `%Order{status: :paid}` unlocks nothing. Unknown, unpaid, and malformed
  references return the same `:base` refusal and write nothing. Fulfillment
  never runs in reverse: a capture creates no deliveries implicitly, and this
  layer never touches a provider, a webhook body, or an amount.
* **Idempotency is a database property** — a unique index on
  `cass_fulfillments.order_item_id` plus `ON CONFLICT DO NOTHING` (never
  read-then-write) makes the trigger safe to replay and safe to run
  concurrently: duplicate calls return the same row, and every line of an order
  is written in one transaction so an order is never half-fulfilled.
* **Completion and grant are one transaction** — `mark_fulfilled/1` writes
  `:fulfilled (+delivered_at)` and grants the entitlement together, so a
  delivery is never reported complete without the grant it implies.
  `cass_entitlements` is 1:1 with the purchased line *and* with the delivery
  that granted it (both unique), and snapshots the purchase (name, SKU,
  quantity, type, metadata) from the immutable order item, so later catalog
  edits cannot rewrite what the buyer bought.
* **Grants are honest and reversible** — statuses `active`/`revoked` plus the
  reserved `expired`; `Entitlement.active?/1` already reports `false` for an
  elapsed `expires_at`, and `revoke_entitlement/2` withdraws the grant
  (`revoked_at` + reason) instead of deleting it. No delivery worker exists yet:
  the milestone stops at the domain boundary, with `kind` recorded and the
  lifecycle driven explicitly.
* **Reads are owner-or-admin, writes are server-side** — the read functions
  take a `Cass.Accounts.Scope` (admin sees all, a buyer sees their own, guests
  see nothing, a foreign/unknown/malformed id is `nil` so ids cannot be probed),
  and an order listing goes through `Orders.get_order/2` so it is never wider
  than the order the scope may already see. Writes take no scope and have no
  route in this milestone. The `:vendor` role gets no extra visibility here.

### Delivery and access (Milestone 8)

* **An entitlement is not a delivery** — an entitlement answers *"does this
  customer hold the right?"*; `Cass.Delivery` answers the separate question
  *"how is that right exercised?"*. Keeping them apart is what lets the delivery
  *mechanism* change without touching an ownership, revocation, or
  purchase-history fact. See [docs/architecture.md](docs/architecture.md).
* **No new table, deliberately** — every input an access decision needs is
  already stored and immutable: `cass_fulfillments` owns the delivery lifecycle
  and its `kind`, `cass_entitlements` owns ownership, status, expiry, and the
  purchase snapshot including the vendor's delivery metadata. A
  `cass_deliveries` table would re-store `user_id`/`order_id`/`order_item_id`
  beside a second lifecycle, with no new fact to show for it. The
  provider-facing state a real object store or SMM API will need is reserved
  for a future delivery-attached table.
* **One authoritative decision** — `Delivery.authorize_access/2` grants only
  when an authenticated scope owns an *active* entitlement whose delivery kind
  has a mechanism. Ownership is resolved by `Entitlements.get_entitlement/2`
  (owner-or-admin), state by the centralized `Entitlement.active?/1`, and there
  is no `user_id` parameter a request could supply.
* **A kind is not a mechanism** — `Fulfillment.kind` is the only taxonomy
  (`digital | smm | ai | manual`, with `:service → :manual`), and
  `Delivery.mechanism_for/1` is the single extension point. Only
  `:digital → :access_code` is implemented; `:smm`, `:ai`, and `:manual` are
  resolved but not yet exercisable, and they **refuse** rather than invent a
  placeholder capability. No provider behaviour and no provider registry yet —
  one implementation is not a reason to build speculative infrastructure.
* **The capability is a narrowed struct, not a re-serialized entitlement** —
  `Cass.Delivery.Access` is built from named fields and has no `metadata` field,
  so no vendor-authored value (a URL, an API key, a token) can reach a buyer
  through a filter that someone could later forget to update. The access code
  is derived from an HMAC over the immutable purchased-line id, so it is
  deterministic per purchase, unforgeable without the server secret, and
  inspect-safe.
* **Refusals are indistinguishable** — unknown, foreign, revoked, elapsed, and
  not-yet-exercisable all return the same `:base` error and render the same
  not-found page, so a probe cannot learn whether an id exists, whose it was, or
  why it failed. `/purchases/:id` is `noindex` and reachable from the buyer's own
  order page rather than from a listing or dashboard.

### Sellers and the account lifecycle (Milestone 9)

* **Applying grants nothing** — `Cass.Vendors` owns the seller profile
  (`cass_vendor_profiles`, one optional row per account). Any signed-in account
  can submit one at `/sell` via `save_profile/2`, which writes a `:pending`
  profile and nothing else. It grants no role, is never shown publicly, and the
  form cannot name a status or a target account: both are written
  programmatically. See [docs/security.md](docs/security.md).
* **The role, not the form, approves a seller** — the status is derived from the
  caller's own roles. An account that already holds `:vendor` has its edits stay
  `:approved`; everyone else is `:pending`, so editing a `:rejected` profile
  resubmits it. Approval runs on the admin review surface `/admin/vendors`
  through `Cass.Vendors.approve_profile/2`, which performs the status change and
  the `:vendor` grant in **one transaction**, so a profile can never be
  approved without the role that lets it act. That is still the only thing that
  grants a role, and it names an application, never a role.
* **Admin review is a context decision** — `list_profiles/1` and
  `get_reviewable_profile/2` return `[]`/`nil` for a non-admin scope, so a
  non-admin gets nothing even by calling the context directly or tampering with
  an event id; the web layer renders the same non-enumerable refusal as the rest
  of the management surfaces.
* **One public seller identity** — `Cass.Vendors.public_name/1` returns the
  `display_name` of an `:approved` profile or `nil`; the storefront's product
  card uses it when present and otherwise falls back to the email-derived handle
  it always used. The public product query preloads `owner: :vendor_profile`, and
  no other profile field reaches the storefront.
* **Deletion is a deactivation, not a hard delete** — orders, fulfillments,
  entitlements, favorites, and roles all reference the account and must survive
  as receipts, so `Cass.Accounts.delete_user/1` stamps `cass_users.deleted_at`
  and, in the same transaction, replaces the email with a non-routable
  `…@cass.invalid` placeholder, replaces the password hash with a random
  secret, and deletes every token. A deleted account is refused at login and on
  session resolution (`User.deleted?/1`, the token query). An account that still
  **owns a product** is refused with `{:error, :owns_products}` until its
  catalog is archived or transferred, so a seller's published work is never
  silently orphaned.
* **Sessions are managed by id, never by value** —
  `Cass.Accounts.list_user_sessions/1`, `revoke_user_session/2`, and
  `delete_user_sessions/1` let `/users/settings` list the account's sessions,
  revoke one, or sign out everywhere. The per-session revoke scopes the delete
  by `user_id`, so a caller cannot end another account's session by naming its
  id, and the page shows the token's row id, never the token.

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
7. ~~Vendor onboarding, admin vendor review, seller profile, session
   management, and account deletion~~ (ownership *transfer* and settlements are
   deliberately deferred: deleting an account that still owns products is
   refused until its catalog is archived or transferred)
8. ~~Checkout and order flow (order items consume variant pricing/stock)~~
9. ~~Payments (capture `awaiting_payment` orders through Paystack, provider
   boundary designed so more gateways slot in)~~
10. ~~Fulfillment (`Cass.Fulfillment`): a paid order owes one tracked delivery
    per purchased line, and completing one grants a durable
    `Cass.Entitlements` grant~~ — plus vendor transfers/settlements
11. AI tools routed through the Nexus AI Gateway
12. JSON catalog API under `/api/v1` (optional, additive)

**Not started:** delivery workers (SMM provider calls, AI credit issuance), real
download storage, signed URLs, physical product fulfillment, and live AI
integrations. Milestone 8 delivers a local digital access code only; the other
three kinds resolve but refuse, and each one that gains a real mechanism is a
single clause in `Delivery.mechanism_for/1` plus its representation in
`Cass.Delivery.Access`.

## Learn more

* Phoenix: https://www.phoenixframework.org/
* LiveView: https://hexdocs.pm/phoenix_live_view/
* Ecto: https://hexdocs.pm/ecto/
* Tailwind CSS v4: https://tailwindcss.com/