# Architecture

## Overview

Cass is a **modular monolith**: a single Phoenix application (one OTP release)
deployed as one unit, with domain logic kept in separate Elixir contexts so it
can later be split if needed. The active stack:

| Layer      | Technology                                   |
| ---------- | -------------------------------------------- |
| Web        | Phoenix 1.8, Phoenix LiveView, Bandit        |
| Data       | Ecto 3, PostgreSQL 18, Postgrex              |
| Automation | Tailwind CSS (v4), esbuild, Heroicons        |
| HTTP       | `Req` (project-wide preferred HTTP client)   |

## Layering rules

* `lib/cass/**` holds **contexts** (e.g. `Cass.Health`, `Cass.Catalog`).
  Contexts own data access and business rules; they never know about the web
  layer.
* `lib/cass_web/**` holds the **web layer**: controllers, LiveViews,
  components, and the router. Web code calls context functions; contexts never
  import from `CassWeb`.
* Templates use the shared components in `CassWeb.CoreComponents` and the
  layouts in `CassWeb.Layouts`. Storefront pages are **server-rendered
  LiveViews for SEO**: each mounted LiveView computes SEO assigns
  (`page_title`, `meta_description`, `canonical_url`, `robots`) that the root
  layout renders, giving crawlers full metadata while keeping interior pages
  interactive. Legacy controller pages remain supported.
* Routes group concerns in the router:
  * `scope "/", CassWeb` — public browser pages
    (health landing page, `/catalog`, `/catalog/categories/:slug`,
    `/catalog/products/:slug`, and the authentication entry points under
    `/users/*`)
  * `scope "/", CassWeb` + `pipe_through [:browser, :require_authenticated_user]`
    — signed-in only (`/users/settings`)
  * `scope "/", CassWeb` + `pipe_through [:browser, :require_vendor_or_admin_user]`
    — sellers and admins only (`/manage/products*`)
  * `scope "/", CassWeb` + `pipe_through [:browser, :require_admin_user]`
    — admins only (`/insights`)
  * `scope "/api/v1", CassWeb.Api.V1` — JSON API (currently only health)

The role guards (`require_admin_user`, `require_vendor_user`,
`require_vendor_or_admin_user`) follow the same shape as
`require_authenticated_user`; see
[Accounts and current scope](#accounts-and-current-scope).

## Product ownership and the management area (Milestone 3 Phase 3)

* `Cass.Catalog.Product` gains a nullable `belongs_to :owner,
  Cass.Accounts.User`. This is the **only** new edge between contexts, and it
  points `Catalog → Accounts`, so no cycle is introduced (`Cass.Accounts` does
  not reference `Cass.Catalog`).
* Ownership is a property of the product, kept separate from roles. The
  authorization predicates live in the context and are the only place the rule
  is written:
  * `can_create_owned_product?/1` — authenticated and `:vendor` or `:admin`.
  * `can_manage_product?/2` — `:admin`, or the product's `owner_id` is the
    caller's user id.
* Product mutations take the caller's scope first
  (`update_product/3`, `publish_product/2`, `archive_product/2`), so a caller
  that reaches the context directly is still checked. Owner-scoped reads
  (`list_managed_products/1`, `get_managed_product/2`) filter in SQL and return
  `nil` rather than a row the caller may not see.
* `create_product/2` remains the **platform** path for trusted server callers
  (seeds, operator tasks) and pairs with `publish_platform_product/1`, which
  refuses to publish an owned product. Nothing reachable from a request uses
  either.
* `CassWeb.ProductManagementLive` is the smallest surface that exercises the
  boundary: `/manage/products` (list, publish, archive),
  `/manage/products/new`, `/manage/products/:id/edit`. It is guarded twice (route
  plug + `on_mount` hook) and re-resolves the product on **every** event, so a
  tampered id behaves like a guessed URL. It is `noindex` and deliberately not a
  seller dashboard.
* The public catalog is untouched: same routes, queries, slugs, SEO, and
  JSON-LD. Public queries do not preload `:owner`, and no public template,
  sitemap entry, or JSON-LD block reads or renders `owner_id`/`owner`.

## Products, variants, and fulfillment (Milestone 4)

Everything sold on CASS is a **Product**. The domain model is
`Category → Product → Product Type → Product Variant → Order Item` (order items
landed with checkout in Milestone 5 and the delivery chain with payments
follow-up milestones 6–7):

* A **Product** is what a seller describes and lists: name, description, SEO,
  category, status/visibility lifecycle, and ownership. It says nothing about
  price or quantity.
* A **Product Type** is the closed vocabulary of what can be sold:
  `:digital`, `:smm`, `:ai`, `:service`. It is owned by
  `Cass.Catalog.product_types/0` and mirrored by a database CHECK constraint
  (`cass_products_product_type_check`), the same single-source
  vocabulary-plus-constraint pattern used for roles (Phase 2). The former
  values `digital_product` / `smm_service` / `ai_tool` were renamed in a
  deterministic data migration (`digital_product→digital`, `smm_service→smm`,
  `ai_tool→ai`); `:service` is new for human-performed work (the first seed is
  the platform's "Manual SEO Audit").
* A **Product Variant** carries what checkout will need: price
  (`price_cents` integer minor units, `currency` defaulting to `USD`), stock
  (`null` = unlimited), and a type-specific `config` JSONB blob (string keys
  only) for purchasable wiring (e.g. `{platform: "tiktok", target_type:
  "followers"}`). Variants are `active` and `sort_order`-ed, purchasable when
  `active` and not out of stock, and named per product
  (`lower(name)` unique within a product) with a globally unique, nullable
  `sku`. A product with no active variants effectively cannot be bought yet.
* Variant mutations reuse the exact Phase 3 ownership surface: every
  `create_variant/3`, `update_variant/3` takes the caller's scope first and
  checks `can_manage_product?/2`; `product_id` is never client input (a
  `%Product{}` is resolved first, then set with `put_change/3`), and refusals
  are the same non-enumerable `{:error, changeset}` with a `:base` message as
  product mutations.
* The public catalog is unchanged: `get_public_product_by_slug/1` now preloads
  `active_variants` (sorted by `sort_order, id`) for pages that want to render
  buy options, but public queries still filter published/active/not-due and
  never expose pricing of hidden variants.
* **`Cass.Fulfillment` is a boundary, not a subsystem.** It maps a product type
  to a fulfillment kind via `kind_for/1` (`:digital`, `:smm`, `:ai`,
  `:manual` for services, `:shipping` for physical goods, defaulting to
  `:manual` for anything unknown) so
  future checkout code can branch without touching product internals. There is
  deliberately **no** fulfillment table, provider, or integration in this
  milestone.

> **Physical goods (delivery seam).** The product-type vocabulary has carried
> `physical` from the start, and `kind_for/1` maps it to `:shipping`. A
> `:shipping` delivery is not automatable (`Delivery.mechanism_for/1` answers
> `nil`) and — unlike every other kind — reaching `:fulfilled` grants **no**
> entitlement (`Fulfillment.grants_entitlement?/1`), because a handed-over
> parcel has no in-app capability. Shipping-rate calculation, address capture,
> and carrier integrations are later milestones; this seam only fixes the branch
> so they need no rewrite.

## Orders and checkout foundation (Milestone 5)

Checkout now exists as a real, transactional boundary in `Cass.Orders`:

* **`Orders.create_order/2` is the only way in.** It takes the caller's
  `Cass.Accounts.Scope` and a minimal list of requested items — each map
  exactly `product_variant_id` + `quantity` (atom or string keys, quantities
  capped at `OrderItem.max_quantity/0`) — and nothing else. The web layer
  exercises it with `POST /orders` (`OrderController#create`) and the
  server-rendered `/orders` and `/orders/:id` pages (`OrdersLive`), behind the
  `:require_authenticated_user` pipe. Paystack capture and fulfillment
  integrations are **not** part of this milestone.
* **Everything money is server-derived.** The variant is the single authority
  on `price_cents`, `currency`, and stock. The client can never provide a
  price, total, currency, ownership, or a served-from id; line totals
  (`unit_price_cents * quantity`) and the order total (the sum, stored as
  `total_cents`) are computed inside the transaction. A client including a
  `price_cents`/`total_cents`/`user_id`/name field simply has it ignored.
* **Single-currency orders.** Every line's currency comes from its variant; if
  the requested lines do not all agree, the whole check-out is refused with
  the generic "not available" error rather than guessing an order currency.
* **The checkout transaction** (`Cass.Orders`, `Repo.transact` following the
  `accounts.ex` `{:ok, _}/{:error, _}` convention): normalize and combine the
  requested ids → resolve variants (preloading product + category) and verify
  sale eligibility (`active` variant, product `published` with
  `:public`/`:unlisted` visibility, category `active`, `published_at` due,
  priced) → reserve stock → insert the order and its snapshot
  items. Any refusal rolls everything back, including already-reserved
  stock.
* **Stock is reserved with an atomic conditional update**
  (`UPDATE ... SET stock = stock - qty WHERE id = ? AND active AND stock >= qty`,
  `nil` stock = unlimited and needs no decrement). The `WHERE stock >= qty`
  clause plus the row lock make the reservation safe under concurrency, and DB
  CHECK constraints (`stock >= 0`, `price_cents >= 0`, added on
  `cass_product_variants` in the orders migration) are the second line of
  defence so a purchase can never push stock or price negative.
* **Order items are historical snapshots.** `product_name`, `variant_name`,
  `sku`, `unit_price_cents`, `currency`, `quantity`, and `metadata` (the
  variant's string-keyed `config`) are copied at checkout, so renaming,
  re-pricing, or archiving a product/variant later never rewrites what a
  customer bought. Both FKs (`order_id`, `product_variant_id`) are
  `on_delete: :restrict`, so order history cannot be destroyed by deleting a
  catalog row or an account.
* **Lifecycle:** `:awaiting_payment` (created by checkout, stock reserved) →
  `:paid` → `:processing` → `:completed`, with `:cancelled`/`:failed` terminal.
  The vocabulary lives in `Cass.Orders.Order.statuses/0`, mirrored by a DB
  CHECK constraint; only the creation state is reachable this milestone — the
  transitions belong to the Payments milestone.
* **Authorization is customer-shaped, not vendor-shaped.** Purchasing is *not*
  catalog management: any `Scope.authenticated?/1` account may buy (a vendor
  buys as a customer), guests are refused at the context *and* at the route.
  Reading follows the ownership convention: an account sees its own orders, an
  admin sees every order, and `get_order/2` returns `nil` for a foreign,
  malformed, or unknown id (non-enumerable, so ids cannot be probed).
* **The public storefront gains a minimal buy surface.** `ProductLive` renders
  a variant + quantity form posting to `/orders` when a published product has
  active variants and the shopper is signed in, a sign-in prompt for guests,
  and keeps the "coming soon" box for products with no variants (existing page
  tests unchanged).

## Payments and capture (Milestone 6)

The `awaiting_payment → paid` transition now exists, driven by provider
agnostic payments in `Cass.Payments` with Paystack as the first adapter:

* **`Cass.Payments` is the payments boundary.** The only stable vocabulary is
  `cass_payments` rows + statuses (`pending`, `processing`, `succeeded`,
  `failed`, `cancelled`, `expired`, `refunded` — an Ecto enum mirrored by a DB
  CHECK, this milestone reaching all but the reserved `expired`/`refunded`).
  A payment **snapshots the order's money** (`amount_cents`, `currency` from
  `order.total_cents`/`order.currency` at init time) and names its `provider`,
  `provider_reference`, checkout URL, and `metadata`; a partial unique index
  `(provider, provider_reference) WHERE provider_reference IS NOT NULL` makes
  reference collisions impossible.
* **Adapters are thin and stateless.** `Cass.Payments.Provider` is a behaviour
  (`name`, `initialize_payment`, `verify_payment`, `parse_webhook`,
  `capabilities`) consumed by `Cass.Payments.Providers` — a config-driven
  registry reading `config :cass, Cass.Payments, providers:` where the disabled
  resolver refuses `{:error, :unknown_provider}`. Provider I/O results are two
  real structs, `Payment.Provider.InitResult` and `CaptureResult`. The Paystack
  adapter is an HTTP client (`Req`, bearer-auth secret from
  `config :cass, :paystack`) that never knows about orders, users, or the DB.
* **Money stays server-derived end to end.** Initialization takes a `Scope`
  and an order id, looks the order up via `Orders.get_order/2` (foreign or
  unknown → the same `{:error, :not_found}`), and only proceeds while the order
  is `:awaiting_payment`. Refusals are non-enumerable: the controller never
  learns whether an id exists, is foreign, or is in the wrong lifecycle state.
* **Idempotent initialization.** CASS generates the `provider_reference`
  (e.g. `"PY-" <> Base.encode32(...)`) and reuses an in-flight `pending`/
  `processing` attempt for the order — a double click returns the *same*
  checkout URL and never recontacts the provider (proved in tests with
  `Req.Test.expect/3`). A provider failure records the attempt `:failed` with
  its `failure_reason`, leaves the order `awaiting_payment`, and refuses with a
  generic "payments are temporarily unavailable" changeset; a later retry then
  creates a fresh attempt.
* **Webhooks reconcile by signature, never by session.** `POST /webhooks/
  paystack` sits outside `:browser`; `Plug.Plug.raw_body_reader` (wired into
  the endpoint's `Plug.Parsers`) hands `PaymentsWebhookController` the exact JSON
  bytes, and the adapter HMAC-SHA512-verifies the `x-paystack-signature`
  against the raw body. Unauthorized bytes get a terse `400`; a correctly
  signed but unknown reference a `404`; every success is acknowledged `200`
  without detail. Webhook authorization is *only* the provider signature.
* **Success pays the payment and the order in one transaction.** The adapter
  normalizes capture data into a `CaptureResult`; the context reconciles it
  against the row by `provider + provider_reference`, cross-checks the
  captured `amount_cents`/`currency` against the snapshot (a mismatch refuses
  — nothing is ever paid from a different amount), then `Repo.transact`s the
  payment to `:succeeded (+ paid_at) together with `Orders.mark_order_paid/1`
  (`:awaiting_payment → :paid`, idempotent). A duplicate success webhook is a
  committed no-op (already `:succeeded`/`:paid`), so a payment can never
  double-pay, and no transaction ever holds the DB open across a network call
  to the provider.
* **Reported failure only deflates the payment.** A signed `failed`/`abandoned`
  webhook moves the payment to `:failed` (reason recorded) or `:cancelled`,
  keeps the order `:awaiting_payment`, and lets the buyer retry.
* **Minimal owner pay surface.** `POST /orders/:id/pay` (`PaymentController`,
  behind `:require_authenticated_user`) authorizes via scope-checked
  `Orders.get_order/2`, initializes, and 302s to the hosted checkout URL;
  `OrdersLive` shows the pay form (`#pay-form` → `#pay-button` with the server
  total) only to the owner of an `:awaiting_payment` order. Guests, strangers,
  unknown ids, and non-payable orders all fail generically.

## Fulfillment and entitlements (Milestone 7)

Two contexts close the post-payment loop, and the point of keeping them apart is
that *how* a purchase is delivered and *whether* the buyer may use it are
different questions:

    paid order → order item → fulfillment → entitlement

Every arrow is a foreign key, so no row can exist without the one it depends on.

* **`Cass.Fulfillment` is the delivery boundary.** It owns `cass_fulfillments`,
  one row per **purchased line** (an order mixing a digital product and a
  human-performed service gets a `:digital` and a `:manual` delivery), with a
  closed status vocabulary (`pending`, `processing`, `fulfilled`, `failed`,
  `cancelled`) mirrored by a DB CHECK and an explicit transition map
  (`pending → processing → fulfilled`, `pending|processing → failed|cancelled`,
  `failed → processing|cancelled`; `:fulfilled` and `:cancelled` are terminal).
  `kind` (`:digital | :smm | :ai | :manual | :shipping`) is resolved once from the
  purchased variant's product type through a single narrow Catalog read —
  `Catalog.get_product_type_for_variant/1`, a projection that keeps delivery
  knowledge out of the Catalog and Catalog knowledge out of delivery — and
  stored, so a delivery worker dispatches on one column and a later catalog edit
  cannot rewrite how a past purchase must be delivered. `kind_for/1` remains the
  one type→kind mapping (`:service → :manual`; unknown or future types degrade
  to `:manual` rather than raising).
* **The paid order is the only authority.** `create_for_paid_order/1` is the
  only way a fulfillment comes into existence and it asks
  `Orders.get_paid_order/1` — not its own judgment — whether the money is
  proven, re-reading the stored row even when handed a struct so a stale or
  forged `%Order{}` cannot unlock anything. Payment verification stays inside
  `Cass.Payments`; this context never talks to a provider, never sees a webhook
  body, and never re-checks an amount. Fulfillment never runs in reverse either:
  nothing in `Cass.Payments` or `Cass.Orders` calls into here, so a capture
  creates no deliveries implicitly and a future trigger (webhook handler,
  worker, admin action) decides *when* to act on a paid order.
* **Idempotency is a database property, not a convention.** A unique index on
  `cass_fulfillments.order_item_id` plus `INSERT … ON CONFLICT DO NOTHING`
  (never read-then-write) means a retried trigger, a duplicated queue job, and a
  concurrent duplicate all converge on the same row: the loser gets the winner's
  record back, and duplicate calls are successes, not errors. All lines of an
  order are written in one `Repo.transact`, so an order is never half-fulfilled.
* **`Cass.Entitlements` is the grant boundary.** `cass_entitlements` is 1:1 with
  the purchased line *and* with the delivery that granted it (both columns
  unique), and it **snapshots** the purchase (product/variant name, SKU,
  quantity, product type, metadata) from the immutable order item, so renaming
  or re-pricing the catalog later cannot rewrite what the buyer bought and the
  row stays readable without joining back. `grant_for_fulfillment/2` is public
  only in the sense that `Cass.Fulfillment` calls it: it is invoked from
  `mark_fulfilled/1` inside that transition's own transaction (completion and
  grant commit or roll back together), and it refuses a fulfillment/order-item
  pair that does not describe the same purchase, so no caller can graft one
  purchase's grant onto another delivery. Statuses are `active`, `revoked`, and
  the reserved `expired`; `expires_at` is honest already —
  `Entitlement.active?/1` reports `false` for an elapsed `expires_at` before any
  expiry job exists — and `revoke_entitlement/2` is a withdrawal (`revoked_at` +
  `revoked_reason`), never a delete.
* **Reads are owner-or-admin; writes are server-side.** `list_for_customer/1`,
  `get_fulfillment/2`, and `list_for_order/2` (and the entitlement twins)
  resolve a `Cass.Accounts.Scope` exactly like `Cass.Orders`: everything for an
  admin, the caller's own rows otherwise, nothing for a guest, and `nil` for a
  foreign, malformed, or unknown id so ids cannot be probed. An order listing
  goes through `Orders.get_order/2` first, so it can never be wider than the
  order the scope may already see. A vendor is a seller, not a delivery
  operator, so the role grants no extra visibility here. Writes take no scope
  and are not reachable from a request: no route exposes fulfillment,
  entitlement, or revocation in this milestone, the same posture as
  `Orders.mark_order_paid/1`.
* **No provider integration yet.** This milestone stops at the domain boundary:
  `kind` is recorded and the lifecycle is driven explicitly. The delivery
  workers it exists for (a `:digital` file, a `:smm` provider call, a `:manual`
  hand-off, an `:ai` grant) come later, and the chain is built so each of them
  only has to claim a row and report an outcome.

## Delivery and access (Milestone 8)

Milestone 7 stopped at the grant. A buyer holding an active entitlement could
prove they *had* a right but there was nothing that said how to *use* it, so
this milestone adds the other half of the chain and keeps the two questions
apart:

    entitlement → delivery / access

    "does this customer hold the right?"  →  Cass.Entitlements
    "how is that right exercised?"        →  Cass.Delivery

That separation is the point. Revocation withdraws the right (an `Entitlement`
fact) without knowing what the right was being used for, and a delivery
mechanism can change — a different provider, a real object store, a human
hand-off — without touching an ownership, expiry, or purchase-history fact.

* **`Cass.Delivery` is the access boundary, and it adds no schema.** No
  migration, no table, no `Ecto.Schema`: every input an access decision needs is
  already stored, and stored immutably. `cass_fulfillments` owns the delivery
  obligation, its lifecycle, and `kind`; `cass_entitlements` owns the buyer's
  identity, status, `expires_at`, and the purchase snapshot *including* the
  vendor's delivery instructions (`metadata`, copied from
  `ProductVariant.config` at checkout). A `cass_deliveries` table would
  re-store `user_id`, `order_id`, `order_item_id`, and `product_type` beside a
  second lifecycle — a denormalization with no new fact to justify it. The
  provider-facing state a real object store or SMM API will need is documented
  where it belongs, on `Cass.Fulfillment.Fulfillment`, as a future
  delivery-attached table.
* **`authorize_access/2` is the one authoritative decision.** It composes three
  facts and grants only when all three hold: an authenticated
  `Cass.Accounts.Scope`, an entitlement that scope owns, and an active
  entitlement whose delivery kind has a mechanism. Ownership is *not*
  re-decided here — it comes from `Entitlements.get_entitlement/2`, which already
  applies the owner-or-admin rule and already returns `nil` for a foreign *and*
  an unknown id. State is *not* re-read either: the check calls the centralized
  `Entitlement.active?/1`, so a revoked grant and an elapsed one are both
  refused without this context knowing what `expires_at` means. There is no
  `user_id` argument anywhere on the path, so a request cannot supply the
  identity it is checked against.
* **A kind is not a mechanism.** `Cass.Fulfillment.kind` remains the single
  taxonomy, and `Delivery.kinds/0` and `kind_for/1` delegate to it rather than
  restating it. `mechanism_for/1` is the one extension point, and the
  distinction keeps the milestone honest: the vocabulary covers every product
  type, while only the kinds whose mechanism exists can be exercised.

      :digital  → :access_code  (implemented)
      :ai       → :ai_gateway   (implemented)
      :smm      → not yet exercisable
      :manual   → not yet exercisable
      :shipping → not exercisable in-app (a physical parcel has no access code)

  The unimplemented kinds **refuse** rather than inventing a placeholder
  capability, so a `:smm` buyer is told the purchase cannot be accessed today
  instead of being handed a broken panel. Each future mechanism is one clause
  here plus its representation in `Cass.Delivery.Access` — with nothing in
  Orders, Payments, Fulfillment, or Entitlements moving, which is the property
  this milestone exists to establish.
* **No provider abstraction yet.** There is deliberately no
  `Cass.Delivery.Provider` behaviour and no registry, because a registry of one
  is speculative. `Cass.Payments.Provider` is the precedent: it was introduced
  when the second gateway had a reason to exist.
* **The capability is narrowed, not re-serialized.** `Cass.Delivery.Access` is a
  plain struct built from named fields, deliberately *not* a schema and not a
  member of the `Entitlement` struct family. An entitlement is a record and is
  therefore complete; an access capability is a response and carries only what
  the holder needs. Because the struct has no `metadata` field, the redaction
  rule is structural — there is no allow-list to forget to update. The
  `:access_code` field is excluded from `Inspect`, so an accidental
  `IO.inspect(access)` cannot put a live credential in a log.
* **The credential is derived, not stored.** The code is an HMAC over the
  entitlement's immutable `order_item_id` under a server-side secret
  (`DELIVERY_ACCESS_SECRET`, injected like the payment secret), rendered as
  `XXXX-XXXX-XXXX-XXXX` in a Crockford-style alphabet — 80 bits, no ambiguous
  `I`/`L`/`O`/`U`, no padding. It is deterministic (a retried request, a second
  tab, and a re-render all show the buyer the same code), unforgeable without
  the secret, and an HMAC output that reveals nothing about it. Derivation is
  **private**: a public "give me the code for this entitlement" function would
  be a second, authority-free way to mint a credential and would quietly become
  the real access decision. It is a local stand-in for a license-key service or
  a signed download grant, added so the boundary is exercisable end to end
  without an external provider.
* **Access is a pure read.** Nothing is written, so there is no read-then-write
  window and nothing to double-insert. Idempotency is inherited from the
  immutable purchase ids rather than re-established with an index.
* **One route, and it is narrow.** `GET /purchases/:id` is the only web surface
  (`CassWeb.PurchaseLive`). It resolves exactly one thing —
  `Delivery.authorize_access(current_scope, id)` — and renders the granted
  capability or the shared not-found state. It is `noindex`, and it is reached
  from the buyer's own order page, which links only the lines that context
  reports as exercisable. There is no listing and no dashboard, so there is
  nowhere to enumerate.
* **Refusals are indistinguishable.** Unknown, foreign, revoked, elapsed, and
  not-yet-exercisable all produce the same `:base` error from the same
  `refuse/0`, and the web layer renders all of them as the same page, so a
  probe cannot learn whether an id exists, whose it was, or why it failed.

## Saved items (favorites)

* `Cass.Favorites` owns one table (`cass_favorites`) and one idea: the pair
  `(user_id, product_id)`, a pin a signed-in account puts on a product it is
  following. No price, note, position, or list of its own — a favorite is the
  pair and nothing else, so the schema cannot grow a second meaning.
* **The scope decides every id.** Each function takes `current_scope` and
  copies `user_id` from `scope.user`; `product_id` comes from the product the
  request already resolved. Neither is cast, requested, or readable from params,
  so no request can pin or unpin on another account's behalf. A guest is not a
  failure mode to defend against but an absence: reads answer `[]`/`false`,
  `add_favorite/2` refuses with the same `:base` error shape used elsewhere,
  and `remove_favorite/2` still answers `:ok`.
* **Idempotent in both directions.** The composite unique index is the identity
  of a pin, so a repeated save keeps one row and returns it, and removing a
  product that was never saved is a no-op — every caller can fire the event it
  means without checking first.
* **Reading goes back through the catalog's public contract.**
  `list_favorite_products/1` resolves ids with
  `Cass.Catalog.list_public_products_by_ids/1`, which applies the same filter
  as `get_public_product_by_slug/1` (published, publication due, `:active`
  category, `:public`/`:unlisted` visibility). A product archived or made
  `:private` after it was saved disappears from the list while the pin
  survives, and the favorites query never probes a row the storefront would
  refuse to show. Sorting is by `inserted_at`, so the newest pin leads without
  a position column.
* **Two surfaces, one toggle.** `CassWeb.ProductLive` renders
  `#favorite-toggle` only when `Scope.authenticated?/1` (a guest sees no
  control to click) and flips the pin in `handle_event("toggle-favorite", ...)`,
  keeping a `:favorited?` assign for the label, icon, and `aria-pressed`.
  `CassWeb.FavoritesLive` (`GET /favorites`, authenticated, `noindex`) lists the
  pins newest first as a LiveView stream with a per-card remove control; the
  product struct for an event or a `stream_delete/3` is held in an
  `id => product` map assign beside the stream, because a stream is not
  enumerable server-side.
* **Both surfaces record `favorite_added` / `favorite_removed`** through
  `CassWeb.LiveAnalytics.track/3`, so the `/insights` funnel sees retention
  alongside product views. The signed-in bottom tab bar carries a `Favorites`
  tab (Home, Catalog, Favorites, Orders, Account), while a guest's bar keeps
  its four tabs and `/favorites` itself redirects to the login page.

## Accounts and current scope

* `Cass.Accounts` owns `cass_users`, `cass_users_tokens`, `cass_user_roles`,
  registration, credential lookup, confirmation, sessions, email changes,
  password resets, and the role API. It has no knowledge of the web layer.
* `CassWeb.UserAuth` is the single seam between the session and the request. It
  provides a browser pipeline plug, LiveView `on_mount` hooks, and
  LiveView-safe guards:
  * `fetch_current_scope_for_user/2` (plug) and `mount_current_scope/1`
    (`on_mount`) resolve the session token — from the signed session, or from
    the signed remember-me cookie — and assign
    `current_scope: Cass.Accounts.Scope.for_user(user)`. A guest is a
    `%Scope{user: nil, roles: %{}}`, not `nil`, so there is one shape to match
    on everywhere.
  * `require_authenticated_user/2` (plug) and `on_mount(:require_authenticated)`
    gate signed-in-only routes. A guest GET is redirected to `/users/log-in`
    with the destination remembered in the session; non-GET requests are not
    remembered.
  * `require_admin_user/2` / `on_mount(:require_admin)` and
    `require_vendor_user/2` / `on_mount(:require_vendor)` gate role-scoped
    routes. They read the same `current_scope`, so a guard never has to look
    anything up itself. A guest is sent to log in; a signed-in account without
    the role is sent to `/users/settings` instead of being shown a bare 403.
  * `log_in_user/3`, `log_out_user/1`, and `disconnect_sessions/1` own session
    creation, revocation, cookie handling, and the LiveView disconnect
    broadcast.
* Every LiveView reads `socket.assigns.current_scope` — the scope is never
  looked up per page, and pages never take a user id from params. The shared
  layout receives `current_scope` and renders either the guest links or the
  signed-in menu plus a log-out form.
* Forms are real browser forms wherever a page must work without JavaScript or
  must survive a cold navigation: login posts to
  `CassWeb.UserSessionController.create/2` (the LiveView form carries
  `phx-trigger-action` so the same markup works either way), log-out submits a
  `POST` with a `_method=delete` override that `Plug.MethodOverride` turns into
  `UserSessionController.delete/2`, and confirmation links are plain
  `CassWeb.UserConfirmationController` redirects so they work from an email
  client on the first request.
* Roles are a separate, small subsystem:
  * `Cass.Accounts.UserRole` owns the closed vocabulary (`roles/0` →
    `[:admin, :vendor]`), input parsing (`parse/1`, no atom interning), the
    grant changeset, and the per-user query. The database check constraint
    mirrors the vocabulary, so the two are never allowed to drift.
  * `Cass.Accounts` exposes the whole role surface — `roles/0`,
    `list_user_roles/1`, `user_has_role?/2`, `grant_user_role/2`,
    `revoke_user_role/2` — and nothing else touches `cass_user_roles` directly.
  * `Cass.Accounts.Scope` resolves roles **server-side, on every scope build**,
    and exposes the nil-safe predicates (`authenticated?/1`, `admin?/1`,
    `vendor?/1`, `role?/2`) that both the plug guards and the LiveView hooks
    ask. One predicate set means "is this allowed" has a single answer in the
    codebase.
  * The account a role is written against is always the `%User{}` handed to the
    context function; `user_id` is set programmatically and never cast, so
    there is no request path that can name the account it wants to promote.
* **No route is role-guarded yet**, and that is intentional: the phase delivers
  the vocabulary, storage, scope, and guards, and the admin/vendor areas that
  will consume them arrive later. Nothing is half-protected in the meantime.
* Roles are bootstrapped by an operator task,
  `mix cass.accounts.create_admin` (`lib/mix/tasks/`), which requires an
  explicit email, takes the password from `--password` or
  `CASS_ADMIN_PASSWORD`, refuses to run in production without `--force`, and is
  safe to re-run. There is no first-user auto-promotion and no HTTP route that
  grants a role.

See [docs/security.md](security.md) for the token, password, and enumeration
controls, and [docs/data-model.md](data-model.md) for the tables.

## Rendering

* Public pages render through `root.html.heex`, which ships full SEO metadata
  (title, description, canonical URL, Open Graph, Twitter card, robots) and
  JSON-LD structured data. Controller pages assign these in the controller;
  storefront LiveViews assign them in `mount/3` (via `CassWeb.Metadata`)
  using the derives-from-URL canonical strategy.
* Not-found / private / draft / archived / scheduled pages do **not** return
  a 404 status (Phoenix LiveView 1.2 has no `put_status/2`); instead they
  render an in-page `<.not_found component>` with `robots: noindex, follow`.
  Real 404 status codes return when a classic action controller handles
  missing routes.
* Catalog lists use LiveView streams (`phx-update="stream"`) with `only:block`
  empty states; SEO-sensitive links never leak unlisted or private items.
* Styling is **hand-written Tailwind CSS v4** in `assets/css/app.css`, with a
  custom `@theme` brand palette (`brand`/`accent`). No third-party UI kit is
  used. Dark mode is driven by a `data-theme` attribute set on
  `<html>` by `root.html.heex`; the Tailwind `dark:` variant is bound to
  `[data-theme=dark]`.

## Configuration

* Environment is captured at config time
  (`config :cass, environment: config_env()`) and exposed by the health
  endpoint as `environment`.
* Database credentials live in `config/<env>.exs` via `config/runtime.exs`
  (env vars in production). Secrets are never in the repo.
* `DELIVERY_ACCESS_SECRET` (Milestone 8) is the server-side secret the digital
  access code is derived under, configured the same way as the payment secret
  and required at least 32 bytes. A missing or short value raises at the point
  of issue rather than silently producing a weakly derived credential, so a
  misconfigured deploy fails loudly instead of handing out guessable codes.

## Testing strategy

* `test/cass_web` — web/controller/liveview tests (ConnCase). Coverage added
  in Milestone 3 Phase 1: `user_auth_test.exs` (plug/LiveView hooks),
  `controllers/user_session_controller_test.exs`,
  `controllers/user_confirmation_controller_test.exs`, and one
  `live/user_*_live_test.exs` per auth page. Phase 2 adds
  `user_authorization_test.exs` (role plug guards and `on_mount` hooks, driven
  through direct `UserAuth` calls with a bare socket so no route is needed).
* `test/cass` — context tests backed by a real PostgreSQL database (DataCase).
  Phase 2 adds `accounts/roles_test.exs` (vocabulary, grant/revoke, database
  constraints, scope resolution). Phase 4 adds `catalog_variant_test.exs`
  (variant schema, pricing/config validation, purchasability, per-product name
  and global SKU uniqueness, scope-first authorization) and
  `fulfillment_test.exs` (product-type → fulfillment-kind mapping). Milestone 5
  adds `orders_test.exs` (snapshotting, server-derived totals, eligibility,
  stock decrement and rollback, tamper resistance, authorized reads, DB
  constraints) and `orders_concurrency_test.exs` (`async: false`, shared
  sandbox, `Task`s) to prove concurrent reservations can never oversell.
* `test/mix/tasks` — operator task tests, added in Phase 2 for
  `cass.accounts.create_admin` (env-var handling, production refusal,
  idempotency, promotion of an existing account).
* The `precommit` alias runs formatter, compile with warnings as errors,
  `deps.unlock --unused`, and the full test suite.
* CI (`/.github/workflows/ci.yml`) replays the same checks against a fresh
  PostgreSQL service on every push.
* Role-specific HTTP behaviour is additionally checked against a running server
  (login with `role` params grants nothing, the session cookie carries no role,
  a grant shows up on the next request and a revoke on the one after).

## Analytics and insights

`Cass.Analytics` is the single write path (`track/2`) and read path for product
and UX measurement; events live in the append-only `cass_analytics_events`
table. A buffered writer (`Cass.Analytics.Writer`) keeps recording off the
request path, the `:browser` pipeline records document page views
(`CassWeb.Plugs.TrackPageView`), and LiveViews emit higher-level events
(`search`, `product_view`) via `CassWeb.LiveAnalytics`. The admin-only
`/insights` dashboard (`CassWeb.InsightsLive`) renders traffic, the purchase
funnel, and the "searches with no results" product-idea feed. Analytics is an
observer: it never influences a business decision and never fails a request.
See [analytics.md](analytics.md).
