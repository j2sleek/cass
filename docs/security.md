# Security

Current status: **Milestone 5 — accounts, authentication, the
`:admin`/`:vendor` role foundation, product ownership, the product-centric
catalog (product types + variants), and transactional checkout with atomic
stock reservation are implemented** (see
[Accounts security](#accounts-and-authentication-milestone-3-phase-1),
[Roles and authorization](#roles-and-authorization-milestone-3-phase-2),
[Product ownership](#product-ownership-milestone-3-phase-3),
[Variants reuse the product check](#variants-reuse-the-product-check-milestone-4),
and [Orders and checkout](#orders-and-checkout-milestone-5)).
Catalog and checkout controls below apply unchanged.

## Threat model and boundaries

### Marketing AI is strictly compliant

CASS **never** provides fake engagement (fake followers, views, or likes),
misleading automation, or content that misrepresents itself. Marketing tools
must be transparent, permission-based, and clearly branded. This is a product
rule enforced at the application layer.

### The Nexus AI Gateway boundary

AI tooling in later milestones is routed **only** through the Nexus AI
Gateway (a sister project, `/root/projects/nexus-ai-gateway`). Cass never
talks to external LLM providers directly:

* Cass sends structured, quota-checked requests to the gateway.
* Gateway credentials, provider keys, and model configs live **only** in the
  gateway's environment — never in Cass.
* Cass rate-limits and logs all AI calls for abuse detection.

## Secrets handling

* No secrets in the repository. Development/test credentials are dev-only
  defaults.
* Production secrets are injected via `config/runtime.exs` environment
  variables.
* `DELIVERY_ACCESS_SECRET` (Milestone 8) signs the digital access code. It is
  read per issuance rather than compiled in, is required to be at least 32
  bytes, and a missing or short value **raises** instead of falling back to a
  default — a misconfigured deploy fails loudly rather than handing out
  guessable codes. The value is never returned to a client, never logged, and
  never included in an error message.
* The health endpoint never returns connection details, hostnames, ports, or
  credentials (enforced by `test/cass_web/controllers/api/v1/health_controller_test.exs`).

## Baseline controls (current)

* CSRF: Phoenix default token handling for browser forms. The `:browser`
  pipeline keeps `protect_from_forgery/2`, and every state-changing request
  carries a `_csrf_token`.
  * The log-out control is a real `<form method="delete">` in both the nav
    (`#log-out-nav-form`) and the settings page (`#log-out-form`): Phoenix
    renders it as `POST` plus a hidden `_method=delete` override, which
    `Plug.MethodOverride` turns into the `DELETE` the router declares, together
    with the CSRF token
    (`test/cass_web/live/user_settings_live_test.exs`).
  * The login page is a LiveView form whose `action`/`method`
    (`phx-trigger-action`) is the same `POST /users/log-in` controller route, so
    it works with and without JavaScript.
  * LiveView events (registration, email change, password reset) ride the
    LiveView channel, which validates the same token from the
    `<meta name="csrf-token">` tag in the root layout.
  * A POST without a token is rejected
    (`test/cass_web/controllers/user_session_controller_test.exs`).
* Session-only cookies; no sensitive data persisted client-side.
* SQL: all queries go through Ecto with parameter binding (no string
  interpolation into SQL).
* HTML is escaped by default in HEEx templates.
* Dependency footprint is minimized; `deps.unlock --unused` runs in CI to
  catch orphaned packages.

## Accounts and authentication (Milestone 3 Phase 1)

### Password storage

* Passwords are hashed with **PBKDF2-HMAC-SHA512** (`pbkdf2_elixir`), 160,000
  rounds in development/production and 1 round in test
  (`config/config.exs`, `config/test.exs`). The hash embeds its own salt and
  iteration count, so it can be re-tuned later without invalidating existing
  passwords.
* The plaintext password is **redacted** on the schema (`:password`,
  `:current_password`, `:hashed_password` are `redact: true`) and is dropped
  from the changeset once hashed, so it cannot reach `inspect/1`, crash
  reports, or logs.
* Length policy is 12–128 characters. The upper bound is a hashing-cost guard,
  not a truncation: PBKDF2 has no 72-byte limit like bcrypt.
* Comparison is constant-time (`Pbkdf2.verify_pass/2`).

### Sessions

* Authentication state is a **revocable random token** in
  `cass_users_tokens` (`context: "session"`), stored in the signed `_cass_key`
  cookie. The cookie holds no user data and cannot be forged: it is signed with
  the endpoint secret, HttpOnly, `SameSite=Lax`, and `secure` in production
  (`secure_cookies` in `config/runtime.exs`).
* Because the token is stored server-side, a session can be revoked instantly.
  Password changes revoke **every** session of the account and broadcast on the
  `cass_users_sessions:<url_encoded_token>` PubSub topic so open LiveViews are
  disconnected (`CassWeb.UserAuth.disconnect_sessions/1`). A password *change*
  made from the settings page keeps only the session that submitted it
  (`keep_session_token`), so a user is not logged out of the tab they are
  working in. A password *reset* revokes all sessions, including the current
  one.
* Session tokens are reissued after 7 days. The superseded token row is
  **deleted** rather than merely overwritten, so a copy of the old cookie
  cannot be replayed after the reissue.
* "Stay signed in for 14 days" adds a second, separately signed, HttpOnly
  cookie (`_cass_web_user_remember_me`) that holds the same revocable token.
  Clearing the session always drops it (`max_age: 0`).
* Logout revokes the token, clears the session, deletes the remember-me cookie,
  and broadcasts the disconnect.

### Account enumeration resistance

* `POST /users/log-in` answers a single generic message — "Invalid email or
  password" — for both unknown addresses and wrong passwords, and echoes the
  submitted address back (truncated to the schema maximum) so the user does not
  have to retype it. The two cases are asserted to be indistinguishable.
* The reset request on `/users/reset-password` renders exactly the same card
  whether or not the address is registered
  (`test/cass_web/live/user_forgot_password_live_test.exs` compares the
  rendered output of both cases).
* Registration and login are the only places where a submitted address is
  echoed. Password-reset links are sent only to the address on file.

### Single-use, address-bound tokens

Confirmation, email-change, and password-reset tokens are random 32-byte
values. Only a **SHA-256 hash** is stored (`cass_users_tokens.token`), so a
database leak does not yield usable links. Every one of them is additionally:

* **Bound to the address it was sent to** (`sent_to` must match the account's
  current address, or the address the change is requested from).
* **Single use**: consumed by the action that succeeds, inside the same
  transaction as the change it authorizes.
* **Expiring**: 168 hours (7 days) for confirmation and email change, 1 hour
  for password reset (`Cass.Accounts.UserToken`).
* **Never an authenticator**: a confirmation link only stamps `confirmed_at` or
  applies a pending email change. It does not create a session, and it does not
  sign out existing sessions.

### Email changes

* A new address is only applied after the **new** mailbox confirms it, so a
  typo cannot lock anybody out of the account.
* Applying the change requires **both** an authenticated session on the old
  address *and* the token mailed to the new one, so neither mailbox alone is
  enough.
* Every token issued for the previous address is revoked when the change lands.

### Scope and authorization

* `Cass.Accounts.Scope` carries the resolved `user` **and** the account's
  `roles` (`MapSet` of `:admin`/`:vendor` atoms), loaded from
  `cass_user_roles` server-side. A guest is `%Scope{user: nil, roles: %{}}`
  rather than `nil`, so there is a single struct to pattern match on.
* `require_authenticated_user/2` and `on_mount(:require_authenticated)` answer
  exactly one question: is there a signed-in user? Role guards are separate
  (`require_admin_user/2`, `require_vendor_user/2`,
  `on_mount(:require_admin)`, `on_mount(:require_vendor)`), so a guest is never
  silently treated as a customer-with-permissions.
* The web layer never trusts an id from the request to identify the acting
  user; it always reads `conn.assigns.current_scope.user`. See
  [Roles and authorization](#roles-and-authorization-milestone-3-phase-2) for
  how roles are resolved.

### Deliberate limitations (Milestone 3 Phase 1)

* **No email provider is wired up.** `Cass.Mailer` uses Swoosh: the local
  adapter in development (`/dev/mailbox`) and the test adapter in tests.
  Selecting a real provider (and its credentials, in `config/runtime.exs`) is a
  deployment concern. Until then, confirmation, email-change, and reset links
  only exist in the Swoosh mailbox.
* **No rate limiting or captcha** on login, registration, or reset requests.
  Enumeration is answered with generic messages, but an attacker can still
  attempt many passwords per second. This is scheduled with the later hardening
  phase; deploying publicly before then requires an edge rate limit.
* **No breached-password or reuse check** (no HIBP k-anonymity lookup).
* **No account deletion, session listing, or "sign out everywhere" page** yet;
  password change and logout are the only session controls.
* **No two-factor authentication.**

## Roles and authorization (Milestone 3 Phase 2)

### The threat

The one thing this phase must make impossible is a client that talks itself into
a privilege it was not granted. Every role-bearing input is untrusted: query
strings, form bodies, JSON, cookies, headers. The rule is that **nothing in the
request may name a role or an account.**

### How roles are resolved

* `CassWeb.UserAuth` builds the scope on every request/LiveView mount from the
  session token, and `Cass.Accounts.Scope.for_user/1` reads the roles from
  `cass_user_roles` in that same call. The session cookie keeps holding only
  opaque tokens — a decoded real session carries `user_token` (and LiveView's
  `live_socket_id` / CSRF token), never a role, a user id, or an email
  (`test/cass_web/controllers/user_session_controller_test.exs`).
* Because the read is per-request, a revoke takes effect on the **next**
  request or mount. There is no cached copy in a cookie or session to
  contradict the database, and an open LiveView does not keep a revoked admin
  signed in as an admin.

### No escalation path exists

* **No route grants or revokes a role.** There is no `PATCH /users/roles`, no
  admin user list, and no self-service promotion. Role changes happen only
  through application code (`Cass.Accounts.grant_user_role/2`,
  `revoke_user_role/2`) or the `mix cass.accounts.create_admin` task, which is
  an operator action on a machine with database access.
* **Login params are not roles.** Posting `user[role]=admin` or
  `user[roles][]=admin` to `/users/log-in`, or `?role=admin` on any page, grants
  nothing — the login controller reads only `email` and `password`
  (`test/cass_web/controllers/user_session_controller_test.exs`), and the
  registered user ends up with no role. Verified against a running server as
  well as in tests.
* **The account a role applies to is never a parameter.**
  `Cass.Accounts.grant_user_role/2` takes a `%User{}` struct and sets
  `user_id` on the row it builds; `UserRole.changeset/2` casts `:role` only, so
  a `user_id` in the same attribute map is ignored.
* **Only known roles exist.** `UserRole.parse/1` maps input through a fixed
  table (trimmed, case-insensitive) and returns `:error` for anything else.
  No `String.to_atom/1` / `String.to_existing_atom/1` is applied to input, so a
  hostile string cannot intern an atom or reach a comparison.
* **The database is the second line of defence.** `cass_user_roles_role_check`
  rejects a role outside the vocabulary, and the unique `[user_id, role]` index
  makes a duplicate grant a no-op instead of a second authority.
* **Guards answer from the database-derived scope only.** The plug guards
  (`require_admin_user/2`, `require_vendor_user/2`) and the LiveView hooks
  (`on_mount(:require_admin)`, `:require_vendor`) read
  `current_scope`, which the request never writes. An admin is **not** implicitly
  a vendor: each is its own grant, checked with its own predicate.
* **No `:customer` role.** "No rows" is the customer state, so being signed in
  never implies a privilege that a later guard would grant.

### Failing closed

* A guest hitting a role-guarded route is sent to `/users/log-in` with the
  destination remembered (GET only).
* A signed-in user *without* the role is sent to `/users/settings` rather than
  shown a bare 403, which avoids advertising the existence of an admin area. The
  flash explains that the account lacks the role.
* An unknown role in the database (only reachable by disabling the constraint)
  is skipped when a scope is built, so it can never be treated as a role and
  cannot take a request down.

### Bootstrap

`mix cass.accounts.create_admin` is the only supported way to get the first
admin, and it is deliberately awkward:

* The email is required on the command line; nothing is inferred from who runs
  it, and **the first account to register is never auto-promoted**.
* The password comes from `--password` or `CASS_ADMIN_PASSWORD`, never from a
  prompt, so it cannot end up in shell history or a transcript by accident.
* In production the task refuses to run without `--force`, so a stray deploy
  hook cannot silently create an admin.
* It touches nothing else: an existing account is promoted in place (its
  password is not changed), and re-running is a no-op.

### Deliberate limitations (Milestone 3 Phase 2)

* **The role guards are not wired to any route yet.** This phase delivers the
  vocabulary, the storage, the scope, and the guards; the admin and vendor areas
  that will use them arrive in later phases. Nothing is exposed in the meantime,
  so there is no half-protected area to get wrong.
* **No role management UI or API.** Granting a role is a console/CLI action on
  purpose. An operator UI is a later decision, and it will need its own
  authorization design (who may promote whom).
* **No audit trail for role changes.** Grants and revocations are not recorded
  in a separate table; `cass_user_roles.inserted_at` shows when a currently held
  role was granted, but a revoke leaves no row behind. An audit log belongs with
  the admin area, not ahead of it.
* **A per-request role query is a deliberate cost.** Every request that builds a
  scope issues one small indexed query. That is the price of not caching
  authorization in the client; if it ever needs optimizing, the fix is a
  short-lived server-side cache, not a cookie.
* **Ownership was not modeled in this phase.** `:vendor` marked an account as a
  seller but granted no rights over any product. Ownership arrives in Phase 3,
  below.

## Product ownership (Milestone 3 Phase 3)

### The threat

A product becomes sellable content. Two failures matter and both are IDORs:
a seller editing or publishing **another seller's** product, and a seller
**claiming** a product that belongs to somebody else (or to the platform) by
naming an owner in a form. Both are prevented by the same rule — ownership is
server-derived data, never client input — plus a check that does not depend on
the web layer.

### Ownership is a fact, not a capability

`cass_products.owner_id` is a nullable FK to `cass_users.id`; `NULL` is the
platform. It is deliberately **independent** of the `cass_user_roles` rows: a
role says what an account may do, the owner id says whose product it is, and
neither implies the other.

| caller   | create owned | manage own | manage others | manage platform |
| -------- | ------------ | ---------- | ------------- | --------------- |
| guest    | no           | no         | no            | no              |
| customer | no           | no         | no            | no              |
| vendor   | yes          | yes        | no            | no              |
| admin    | yes          | yes        | yes           | yes             |

A platform product is admin-only by construction: `can_manage_product?/2`
matches on `product.owner_id == scope.user.id`, and `nil` can never equal a user
id (nor does a guest have one).

### The check is in the context, not only in the route

Every product mutation takes the caller's `Cass.Accounts.Scope` as its first
argument and checks `can_create_owned_product?/1` or `can_manage_product?/2`
**before** the row is read for writing:

```elixir
def update_product(%Scope{} = scope, %Product{} = product, attrs) do
  if can_manage_product?(scope, product) do
    product |> Product.update_changeset(attrs) |> Repo.update()
  else
    not_authorized(product, @not_authorized_to_manage)
  end
end
```

This is stricter than guarding the route. A missing `on_mount` hook, a new
caller, or a console task all hit the same check, so authorization cannot be
skipped by reaching the context directly.

### Refusals are not enumerable

* A refusal is `{:error, changeset}` with a single `:base` message that never
  distinguishes "not yours" from "does not exist", so a probe cannot learn
  whether a product id exists.
* `get_managed_product/2` filters by the caller's rights **in SQL** and returns
  `nil` for anything else. The management UI renders the same not-found page for
  a foreign product as for a nonexistent one.
* `get_product!/1` — an unfiltered primary-key getter that predated ownership —
  was **removed**. With owner-scoped rows in the table it was a guaranteed IDOR
  footgun and it had no callers.

### `owner_id` is not an input

* `owner_id` is absent from `Product.changeset/2`'s cast list, so Ecto drops it
  from `params` before validation; `create_owned_product/3` writes
  `scope.user.id` itself. A submitted `owner_id` is **ignored, not rejected**:
  there is no error to teach an attacker the field exists, and the resulting
  product still belongs to whoever is signed in.
* Ownership is immutable after creation, since `Product.update_changeset/2` does
  not cast it either. There is no transfer API, route, or UI.
* `owner_label/2` renders "Yours" / "Seller" / "Platform" in the management UI
  and the owner's email is never rendered. The public queries do not preload the
  `:owner` association, and the public layer — product pages, category pages,
  search, sitemap, and JSON-LD — never reads, renders, or serializes
  `owner_id`/`owner`. The column still exists on the struct those queries
  return, so the guarantee is enforced by the public code path (covered by
  `test/cass/catalog_ownership_test.exs` and
  `test/cass_web/live/catalog_pages_test.exs`), not by the schema.

### Web layer

* `/manage/products`, `/manage/products/new`, and `/manage/products/:id/edit`
  sit behind `require_vendor_or_admin_user` (plug) **and**
  `on_mount(:require_vendor_or_admin)` (LiveView), so a guest is sent to log in
  and a customer is redirected away with a "not authorized" flash.
* The nav link is rendered from the same `can_create_owned_product?/1` predicate
  the context enforces, so the UI cannot advertise an area the context refuses.
* The pages carry `robots: noindex, nofollow`.
* Every action re-resolves the product through `get_managed_product/2` with the
  socket's `current_scope`, so a tampered `product_id` in an event payload
  resolves to nothing — the same treatment as a guessed URL.

### Variants reuse the product check (Milestone 4)

Product variants are the pricing/stock surface of the products above, and they
inherit its threat model:

* `create_variant/3` and `update_variant/3` take the caller's scope **first**
  and call `can_manage_product?/2` before any write, mirroring
  `update_product/3`. A seller editing variants of another seller's (or the
  platform's) product gets the same non-enumerable `{:error, changeset}` with a
  `:base` message as every other refusal.
* `product_id` is **never an input**. Callers resolve a `%Product{}` (via the
  same owner-scoped reads) and the context writes `product_id` with
  `put_change/3`; a `product_id` inside the attribute map is ignored because it
  is absent from the variant changeset's cast list.
* `sku` and the partial `[product_id, lower(name)]` uniqueness are enforced at
  the database level (unique constraints), so even a direct write cannot create
  two SKUs or two same-named variants of one product.
* The public path is untouched: `get_public_product_by_slug/1` preloads only
  `active_variants` for product pages, and the storefront never exposes the
  variants of a non-published/future/private product (covered by
  `test/cass/catalog_variant_test.exs`).
* Product types are a closed vocabulary mirrored by a CHECK constraint; a type
  string that does not map to an existing atom is rejected (no atom interning
  from input), so a hostile `product_type` cannot widen the vocabulary.

### Deleting an account is a database decision

`on_delete: :restrict` means the database refuses to delete a user who still
owns a product. `Cass.Accounts` has no `delete_user/1` today, so the constraint
is currently a guard rail; when account deletion lands it must transfer or
archive first. This is why ownership **transfer** is deferred rather than
skipped: it is the operation that would have to be designed and authorized
before deletion could be offered.

## Orders and checkout (Milestone 5)

Checkout introduces the first write path regular customers can reach, so it
gets its own threat model:

### The threat

An attacker driving `POST /orders` (or calling `Cass.Orders` directly) could
try to underpay, steal stock, or probe the catalog: sending their own
`price_cents`/`total_cents`, a negative or zero total, an out-of-stock
quantity, a foreign `user_id`, a disabled/unpriced variant, or malformed item
shapes.

### Money is server-derived, never client input

* The changeset casts **only** `number`, `status`, `total_cents`, `currency`;
  `user_id` (and the order's items) are written with `put_change/3` from data
  the server resolved. Attributes map keys like `price_cents`, `total_cents`,
  `currency`, `user_id`, `product_name`, `variant_name` are simply absent from
  the cast lists, so a tampered request is ignored field-by-field rather than
  refused (so probing is not rewarded with detail).
* Every line total is `unit_price_cents * quantity` where both come from the
  variant row and a validated quantity (1..`max_quantity`); `total_cents` is
  the server sum. A line is never priced from the request.
* Money is integer minor units with DB CHECK constraints `>= 0`, so no
  computation can go negative.

### Stock is reserved atomically, and cannot oversell

* The reservation is one statement:
  `UPDATE cass_product_variants SET stock = stock - qty WHERE id = ? AND active AND stock IS NOT NULL AND stock >= qty`.
  A concurrent buyer whose `WHERE stock >= qty` is now false gets zero rows and
  a refusal. Because each statement takes a row lock on the variant, and the
  whole checkout is one transaction, the invariant `stock >= 0` holds even
  under overlapping requests (`test/cass/orders_concurrency_test.exs`).
* Unlimited variants (`stock IS NULL`) are not written at all.
* Eligible-but-refused purchases roll back all lines, so a 5-line order that
  fails on line 4 takes no stock and produces no order.

### Eligibility errors are not enumerable

A variant that is `inactive`, un-priced, out of stock, or whose product is
not `published`, is `:private`, or is in a non-`:active`/not-due category all
resolve to the same generic "an item in the order is not available for
purchase" `:base` error — and malformed input to a separate "the order request
is invalid". A direct caller learns nothing about *cause* or *which* item.

### Order records are tamper-proof and capability-based to read

* `cass_orders` never exposes a client-controlled field that changes money,
  and only `Cass.Orders` can write it.
* `list_orders/1` is owner-or-admin, scoped in SQL; `get_order/2` returns
  `nil` for foreign/unknown/malformed ids — a stranger's order number cannot be
  guessed or probed (`/orders/:id` shows the same not-found state).
* `OrdersLive` sits behind the `:require_authenticated_user` live_session with
  `current_scope` passed through, and redirects guests to log in. `POST /orders`
  is guarded the same way at the controller.
* Order items snapshotted at checkout (`on_delete: :restrict` on both FKs)
  mean later re-pricing, renaming, archiving, or (eventually) deleting a
  product/variant cannot rewrite or strand a receipt.

### Deliberate limitations (Milestone 5)

* **No payment capture.** `:awaiting_payment` is the only reachable status;
  money is never actually collected, so there is no payment-card/PCI surface to
  review yet. Cancellation/refund/reversal paths do not exist yet.
* **No vendor side of orders.** Sellers cannot yet see "orders for my
  products", payouts resolve nothing, and fulfillment is still the
  `Cass.Fulfillment` mapping seam only.
* **Stock is not transactional inventory accounting.** The context exposes no
  "restock"/"adjust" API and no audit of the decrement (the `stock` change is
  the snapshot), consistent with "no audit trail" elsewhere in this milestone
  group.

### Deliberate limitations (Milestone 3 Phase 3)

* **No transfer.** An account that loses the `:vendor` role keeps managing the
  products it already owns (the owner branch does not re-check roles), and
  there is no way to hand a product to another account — not through the UI, not
  through the context.
* **No suspended/disabled state.** The owner branch does not require a current
  role, so a revoked vendor keeps managing their catalog. That is intentional
  (revoking a role should not orphan a seller's products, and there is no
  transfer feature to migrate them with), but a future moderation feature may
  want an explicit `suspended_at`.
* **The management area is minimal by design** — list, create, edit, publish,
  archive. No pricing, orders, payouts, or onboarding, so there is no second
  authorization surface to review yet. (Variants exist at the *context* level
  with full scope-first authorization but have no management UI yet, so there
  is still no additional web surface to review.)
* **No audit trail** for publish/archive/ownership changes, consistent with
  Phase 2's role limitation.

## Fulfillment and entitlements (Milestone 7)

This milestone adds no HTTP surface at all: no route, no LiveView, no form.
That is the primary security property, so it is stated first.

* **Nothing is reachable from a request.** `Cass.Fulfillment.create_for_paid_order/1`,
  the `mark_processing/1`/`mark_fulfilled/1`/`mark_failed/2`/`mark_cancelled/1`
  transitions, `Cass.Entitlements.grant_for_fulfillment/2`, and
  `revoke_entitlement/2` take **no scope** and have no route, in the same
  posture as `Cass.Orders.mark_order_paid/1` (which only `Cass.Payments` calls,
  after a signature-verified capture). A request body can never name a
  `user_id`, an `order_id`, an `order_item_id`, a `kind`, or a grant. The router
  diff for this milestone is empty by design.
* **Ownership is derived, never supplied.** `cass_fulfillments.user_id` is
  copied from the paid order and `cass_entitlements.user_id` from the
  fulfillment; neither appears in a changeset cast list, so a submitted
  `user_id` is ignored — the same rule as `orders.user_id`.
* **The paid order is the authorization for creating anything.**
  `create_for_paid_order/1` re-reads the stored order through
  `Orders.get_paid_order/1` even when it is handed a struct, so a stale or
  forged `%Order{status: :paid}` cannot unlock a delivery. Unknown, unpaid, and
  malformed references return the *same* `:base` changeset
  ("the order has not been paid") and write nothing, so the boundary cannot be
  used to probe which order ids exist. Payment verification itself remains
  entirely inside `Cass.Payments`, which owns provider signature checks; this
  layer never handles a webhook body, a provider secret, or an amount.
* **Reads are owner-or-admin, and non-enumerable.** `list_for_customer/1`,
  `get_fulfillment/2`, and `list_for_order/2` (plus the entitlement twins) take
  a `Cass.Accounts.Scope`: an admin sees everything, a buyer sees only their
  own, a guest sees nothing, and a foreign, malformed, or unknown id is `nil` —
  indistinguishable from a missing row, so fulfillment and entitlement ids
  cannot be enumerated. `list_for_order/2` resolves the order through
  `Orders.get_order/2` first, so an order listing is never wider than the order
  the scope may already see.
* **The vendor role grants nothing here.** A vendor is a seller, not a delivery
  operator: `:vendor` gets no extra visibility over deliveries or entitlements,
  so possessing it cannot be escalated into reading a buyer's grants.
* **Database constraints back up every application check.** Closed vocabularies
  (`status`, `kind`, `product_type`) and positive quantities are CHECK
  constraints, mirroring the Ecto enums; every foreign key is
  `on_delete: :restrict`, so deleting a catalog row, order, or account can never
  silently destroy a delivery obligation or a grant. The unique indexes on
  `cass_fulfillments.order_item_id`, `cass_entitlements.order_item_id`, and
  `cass_entitlements.fulfillment_id` make duplicate work impossible even against
  a direct write or a racing worker, rather than relying on a read-then-write
  check in application code.
* **Grants are append-only history.** Revocation is a withdrawal
  (`status`/`revoked_at`/`revoked_reason`), never a delete, and a completed or
  cancelled delivery is terminal — so a grant cannot be orphaned by a later
  cancel and a support question about a revoked purchase still has an answer.
* **Known gaps, deliberately.** There is no audit trail for delivery
  transitions or entitlement revocations, no admin/support surface to review,
  and no download accounting yet; those arrive with the delivery workers and
  the admin milestone, and the tests in
  `test/cass/fulfillment_test.exs`, `test/cass/entitlements_test.exs`,
  `test/cass/fulfillment_concurrency_test.exs`, and
  `test/cass/fulfillment_integration_test.exs` cover the rules above.

## Delivery and access (Milestone 8)

This milestone adds the first read surface over a grant: one authenticated
route, `/purchases/:id`, that shows a buyer how to use a purchase they hold.

* **Authorization is derived from the session, never from the request.**
  `Delivery.authorize_access/2` takes a `Cass.Accounts.Scope` and an
  entitlement id. There is no `user_id`, `customer_id`, or `owner_id` parameter
  anywhere on the path, so there is no field for a caller to forge — the only
  identity in play is the scope `CassWeb.UserAuth` resolved server-side.
* **One authoritative decision, composed from centralized facts.**
  The check grants only when an authenticated scope owns an *active* entitlement
  whose delivery kind has a mechanism. Ownership comes from
  `Entitlements.get_entitlement/2` (owner-or-admin, already non-enumerable) and
  state from the centralized `Entitlement.active?/1`, so a revoked grant and a
  grant whose `expires_at` has elapsed are both refused without this layer
  reimplementing the rule — and without a second place for it to be wrong.
* **Refusals are indistinguishable.** Unknown id, somebody else's id, revoked,
  elapsed, and not-yet-exercisable all return the same `:base` error from the
  same `refuse/0`, and the web layer renders all of them as the same not-found
  page. A probe cannot learn whether an entitlement id exists, whose it was, or
  why access failed. The two pages are identical in their visible text, which is
  pinned by test.
* **The capability cannot carry a leak.** `Cass.Delivery.Access` is built from
  named fields and has no `metadata` field at all, so the vendor's
  catalog-authored delivery instructions — a download URL, an API key, a token, a
  license pool — have no path to a buyer. The rule is structural rather than a
  filter, so there is no allow-list to forget to update later. The
  `:access_code` field is excluded from `Inspect`, so an accidental
  `IO.inspect(access)` cannot put a live credential in a log.
* **The credential is not forgeable.** The access code is an HMAC-SHA256 over the
  entitlement's immutable `order_item_id` under `DELIVERY_ACCESS_SECRET`,
  truncated to 80 bits and rendered in a Crockford-style alphabet. A buyer
  cannot invent a code for a purchase they do not hold, and an HMAC output
  reveals nothing about the secret. Its derivation is **private**: a public
  "give me the code for this entitlement" function would be an authority-free
  second way to mint a credential, and would quietly become the real access
  decision.
* **The surface is narrow on purpose.** One route, no listing, no dashboard, and
  the page is `noindex`. It is reached from the buyer's own order page, which
  links only the lines the delivery context reports as exercisable. There is
  nowhere to enumerate, and nothing to see before signing in.
* **Unimplemented kinds fail closed.** A `:smm`, `:ai`, or `:manual` purchase is
  refused rather than handed a placeholder capability, so a partially built
  feature cannot appear to work.

## Input handling conventions (for future features)

* `String.to_atom/1` is forbidden on user input (atom-table exhaustion
  risk); use `String.to_existing_atom/1` only when safe.
* Ecto changesets whitelist castable params; foreign keys are never taken
  from user input.
* User-supplied slugs/content get server-side validation and length limits.

## Catalog exposure rules (Milestone 2)

* The public storefront is read-only: no guest mutation routes exist yet, and
  browsing never requires authentication.
* Discoverability is enforced in `Cass.Catalog`, not in templates:
  * `list_public_*` / `get_public_*` queries filter on `status == :published`,
    `status == :active` (categories), `visibility` (products), and
    `published_at <= now`. Draft, archived, `:private`, not-yet-due, and
    category-archived items are never part of any public query result.
  * `:unlisted` products are served by direct slug lookup but excluded from
    listings and marked `robots: noindex, follow`.
  * Unknown/restricted slugs render an in-page not-found state with `noindex`
    rather than leaking row existence.
* Foreign keys (`category_id`, `parent_id`, `owner_id`) are never accepted from
  params; they are set programmatically, and create/update guard against
  archived parents/categories.
* Slugs are validated (`[a-z0-9]+(?:-[a-z0-9]+)*`, length-capped) and unique
  at the database level; category names are unique among siblings
  case-insensitively via partial unique indexes.
* SEO fields (`seo_title`, `seo_description`, `canonical_url`) are length-
  limited and *output-escaped* by HEEx; `canonical_url` must be an absolute
  http(s) URL.

## Incident notes

Any committed secret, a leaked password hash or raw token, or any report of the
health endpoint leaking configuration, is a P0. Rotate the credential, revoke
exposure, and add a regression test.

For authentication specifically:

* A leaked **session** token is revoked by deleting its row in
  `cass_users_tokens` (or by any password change, which revokes all of them).
* A leaked **confirmation/reset** link is neutralized by deleting its row; the
  hashes are useless without the raw token.
* A suspected password leak means forcing a reset for the affected account, not
  waiting for expiry.

For roles:

* A wrongly granted role is removed by revoking it
  (`Cass.Accounts.revoke_user_role/2`, or
  `DELETE FROM cass_user_roles WHERE user_id = $1 AND role = $2`). The next
  request or LiveView mount already sees the revocation — there is no session
  to invalidate.
* A compromised **admin account** still warrants a password change: that revokes
  every session for the account, which is the only way to cut off an open tab
  immediately.
