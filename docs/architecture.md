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
and fulfillment integrations land with checkout in a later milestone):

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
  `:manual` for services, defaulting to `:manual` for anything unknown) so
  future checkout code can branch without touching product internals. There is
  deliberately **no** fulfillment table, provider, or integration in this
  milestone.

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
