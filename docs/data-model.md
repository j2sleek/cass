# Data Model

Current status: **Milestone 5 — checkout exists on the product-centric
catalog.** Everything sold on CASS is a `Product`, priced and stocked at the
**product variant** level, with a closed product-type vocabulary
(`digital | smm | ai | service`). Orders now snapshot what was bought (names,
SKU, price, currency, quantity, config) and reserve stock atomically. Eight
domain tables exist: the three catalog tables below, `cass_orders` and
`cass_order_items` (this milestone), plus `cass_users`, `cass_users_tokens`,
and `cass_user_roles`, all owned by the `Cass.Catalog`, `Cass.Orders`, and
`Cass.Accounts` contexts. Payments, entitlements, and AI tool runtime data
arrive in later milestones.

## Naming and conventions

* Ecto schemas live in `lib/cass/<domain>/` (e.g. `Cass.Catalog.Category`,
  `Cass.Catalog.Product`).
* Fields use `:string` by default (`Ecto.Schema` guideline); long free-text
  columns (`description`) use `:text` in the migration. Time fields use
  `:utc_datetime` matching the generator setting.
* Foreign keys (`*_id`) are **not** cast from user params; they are set
  programmatically during create to enforce security rules.
* Migrations are generated with `mix ecto.gen.migration <name>` so timestamps
  and file layout follow convention.

## Implemented schema (Milestone 2)

### `cass_categories`

| Column        | Type        | Notes                                     |
| ------------- | ----------- | ----------------------------------------- |
| `id`          | bigint      | PK                                        |
| `slug`        | string      | Unique, lowercase `[a-z0-9]+(?:-[a-z0-9]+)*`, immutable once archived |
| `name`        | string      | Unique among siblings, case-insensitive   |
| `description` | text        | Optional, plain text                      |
| `seo_title`   | string      | Optional                                  |
| `seo_description` | string | Optional                                  |
| `status`      | enum        | `active` \| `archived` (archived = immutable) |
| `parent_id`   | bigint      | Self-FK (`on_delete: :restrict`); null = root |
| `inserted_at` / `updated_at` | utc_datetime | |

Indexes: unique `slug`; partial unique indexes on `name` for organizations —
one for roots (`parent_id IS NULL`) and one per parent scope
(`parent_id = X`), both comparing `lower(name)`. This allows the same
category name ("Services") at different parents/roots while rejecting
duplicate sibling names regardless of case.

### `cass_products`

| Column        | Type        | Notes                                     |
| ------------- | ----------- | ----------------------------------------- |
| `id`          | bigint      | PK                                        |
| `category_id` | bigint      | FK `cass_categories` (`on_delete: :restrict`), required |
| `slug`        | string      | Unique, lowercase `[a-z0-9]+(?:-[a-z0-9]+)*`, **immutable once published or archived** |
| `name`        | string      | Required, not unique                      |
| `product_type`| enum        | `digital` \| `smm` \| `ai` \| `service`   |
| `status`      | enum        | `draft` \| `published` \| `archived`      |
| `visibility`  | enum        | `public` \| `unlisted` \| `private`       |
| `featured`    | boolean     | Default `false`; showcase flag only, does not affect queries |
| `short_description` | string | Optional, used on cards / previews |
| `description` | text        | Optional, plain text                      |
| `seo_title`   | string      | Optional                                  |
| `seo_description` | string | Optional                                  |
| `canonical_url` | string    | Optional/reserved alternate canonical, validated as absolute http(s) |
| `published_at`| utc_datetime | Null until publish; public queries require `published_at <= now` (`nil` = not due) |
| `owner_id`   | bigint      | FK `cass_users` (`on_delete: :restrict`), **nullable**, indexed. `NULL` = platform-owned |
| `inserted_at` / `updated_at` | utc_datetime | |

Index: unique `slug`, plus a plain (non-unique) `owner_id` index for the
seller's "my products" query. CHECK constraints enforce the enum domains
(`product_type`, `status`, `visibility`); the publish-only-drafts and
publish-into-active-category guards live in the `Cass.Catalog` context layer.

### `cass_product_variants` (Milestone 4)

Everything that checkout will need is priced and stocked on a **variant**, not
on the product:

| Column        | Type        | Notes                                     |
| ------------- | ----------- | ----------------------------------------- |
| `id`          | bigint      | PK                                        |
| `product_id`  | bigint      | FK `cass_products` (`on_delete: :restrict`), required |
| `name`        | string      | Required, e.g. "1,000", "Pro tier"        |
| `sku`         | string      | Optional, **globally unique**, immutable once set |
| `price_cents` | integer     | Optional, integer minor units (no floats); `null` until priced |
| `currency`    | string      | Default `"USD"` (ISO 4217, uppercase)     |
| `stock`       | integer     | Optional; `null` = unlimited, `0` = out of stock |
| `active`      | boolean     | Default `true`; one of the purchasability gates |
| `sort_order`  | integer     | Display/choice order, ascending           |
| `config`      | jsonb       | Type-specific purchasable config, **string keys only** |
| `inserted_at` / `updated_at` | utc_datetime | |

Indexes: `product_id` (non-unique); partial `active`; unique
`[product_id, lower(name)]` (`cass_product_variants_product_name_index`) so no
two variants of one product share a name case-insensitively; unique partial
`sku WHERE sku IS NOT NULL` (`cass_product_variants_sku_index`). A product
belongs to a variant pivot table none other: `cass_product_variants` is the
only row source for pricing/stock, so a product with no active variants
effectively cannot be purchased yet.

Milestone 5 adds two CHECK constraints to this table as the database's second
line of defence for checkout: `stock is null or stock >= 0` and
`price_cents is null or price_cents >= 0`. The application enforces these in
the variant changeset already; the constraints guarantee a successful purchase
can never strand a negative stock or price, even against a direct write.

### `cass_orders` (Milestone 5)

An order is the immutable record of a purchase. Its `total_cents` is the
server-summed line total — never a client value.

| Column      | Type       | Notes                                        |
| ----------- | ---------- | -------------------------------------------- |
| `id`        | bigint     | PK                                           |
| `number`    | string     | Unique, server-generated `C-` + 10 base32 uppercase chars |
| `user_id`   | bigint     | FK `cass_users` (`on_delete: :restrict`), required; owner of the order |
| `status`    | string     | CHECK: one of `awaiting_payment`, `paid`, `processing`, `completed`, `cancelled`, `failed`; default `awaiting_payment` |
| `total_cents` | integer  | CHECK `>= 0`; integer minor units, server-derived |
| `currency`  | string     | Default `"USD"` (ISO 4217); must match every line |
| `inserted_at` / `updated_at` | utc_datetime | |

Indexes: unique `number`; `user_id`; `status`. The CHECK on `status` mirrors
`Cass.Orders.Order.statuses/0`, the same vocabulary-plus-constraint pattern
used for product types and roles. Foreign keys are `on_delete: :restrict`: an
account that has ordered cannot be deleted out from under its history.

### `cass_order_items` (Milestone 5)

A purchased line, and a **historical snapshot** of the commercial facts at
checkout time.

| Column              | Type       | Notes                                        |
| ------------------- | ---------- | -------------------------------------------- |
| `id`                | bigint     | PK                                           |
| `order_id`          | bigint     | FK `cass_orders` (`on_delete: :restrict`), required |
| `product_variant_id`| bigint     | FK `cass_product_variants` (`on_delete: :restrict`), required |
| `product_name`      | string     | Snapshot, required (max 120)                 |
| `variant_name`      | string     | Snapshot, required (max 120)                 |
| `sku`               | string     | Snapshot, optional (max 60)                  |
| `unit_price_cents`  | integer    | Snapshot, required, CHECK `>= 0`; integer minor units |
| `currency`          | string     | Default `"USD"`, required                    |
| `quantity`          | integer    | Required, CHECK `> 0`, capped at `OrderItem.max_quantity/0` (100_000) |
| `metadata`          | jsonb      | Snapshot of the variant's `config` (string keys only), default `{}` |
| `inserted_at` / `updated_at` | utc_datetime | |

Indexes: `order_id`; `product_variant_id`. Line totals are never stored —
`unit_price_cents * quantity` is derived by `OrderItem.line_total_cents/1`,
and the order's `total_cents` is the sum (`Orders.order_total_cents/1`). Both
FKs are `on_delete: :restrict`, so re-pricing, renaming, or archiving a
product/variant later can never rewrite what a customer bought.

### `cass_categories`

#### `owner_id` (Milestone 3 Phase 3)

* **Nullable, and `NULL` means the platform.** A product is either CASS's own or
  one account's. No system/platform user exists, no row was backfilled, and the
  six products that existed before this phase are still platform-owned — the
  smallest truthful state, and one that needs no fake data to be correct.
* **`on_delete: :restrict`.** Deleting an account that still owns a product is
  refused by the database (`confdeltype = 'r'`). `Cass.Accounts` has no
  `delete_user/1` yet, so this is a guard rail rather than a live code path: when
  account deletion lands it must transfer or archive first. Cascading would
  silently destroy a catalog, and nulling the owner would quietly hand a seller's
  listings to the platform, so neither is acceptable.
* **Indexed, not unique.** One account owns many products, and a seller's
  management listing filters on `owner_id`.
* **Not castable.** `owner_id` is absent from `Cass.Catalog.Product.changeset/2`'s
  cast list; `Cass.Catalog.create_owned_product/3` writes `scope.user.id` with
  `put_change/3`. A submitted `owner_id` is ignored, and no code path transfers
  ownership.

### Timestamps and `:utc_datetime`

`:utc_datetime` columns reject microsecond precision at write time, so all
code must truncate: `DateTime.utc_now() |> DateTime.truncate(:second)`
(encapsulated as `Cass.Catalog.utc_now/0`). Test setups reuse the same
function to stamp `published_at` for scheduling tests.

## Accounts schema (Milestone 3 Phase 1)

### `cass_users`

| Column        | Type        | Notes                                     |
| ------------- | ----------- | ----------------------------------------- |
| `id`          | bigint      | PK                                        |
| `email`       | string      | Required, ≤160 chars, stored trimmed and downcased |
| `hashed_password` | string  | PBKDF2-HMAC-SHA512, redacted in the schema |
| `confirmed_at`| utc_datetime | Null until the emailed link is opened     |
| `inserted_at` / `updated_at` | utc_datetime | |

Index: unique `lower(email)` (`cass_users_email_index`). Uniqueness is enforced
at the database level **and** pre-checked in the changeset for a friendly error
message. Canonicalization happens in the changeset, so an address is stored in
exactly one form and cannot be registered twice with different casing.

There are deliberately **no** `role`, `is_vendor`, `owns_*`, or profile columns
on `cass_users`: roles live in a join table (below) so an account can hold more
than one, and ownership does not exist yet (see [security.md](security.md)).

### `cass_users_tokens`

| Column        | Type        | Notes                                     |
| ------------- | ----------- | ----------------------------------------- |
| `id`          | bigint      | PK                                        |
| `user_id`     | bigint      | FK `cass_users` (`on_delete: :delete_all`) |
| `token`       | binary      | SHA-256 hash of the raw token (or the raw session token) |
| `context`     | string      | `session` \| `confirm` \| `reset_password` \| `change:<current email>` |
| `sent_to`     | string      | Address the token was mailed to           |
| `inserted_at` | utc_datetime | Used as the issue time (expiry, reissue) |

Indexes: unique `token`; `user_id_and_contexts_index`; `user_id_and_contexts_expire_index`
for expiry sweeps.

Token storage rules:

* `context: "session"` stores the **raw** token. It is a credential the database
  must be able to look up on every request, and it is protected by the signed,
  HttpOnly cookie that carries it.
* Every other context stores only `:crypto.hash(:sha256, raw_token)`. A dump of
  this table therefore yields no usable confirmation, email-change, or reset
  links.
* `context` for an email change embeds the address the change was requested
  **from** (`change:<old email>`), so a link stops working once the address has
  changed. `sent_to` binds it to the new address.
* Expiry is derived from `inserted_at` (7 days for confirm/change, 1 hour for
  reset, 60 days for sessions) rather than stored, so there is nothing to keep
  in sync.

## Authorization schema (Milestone 3 Phase 2)

### `cass_user_roles`

| Column        | Type        | Notes                                     |
| ------------- | ----------- | ----------------------------------------- |
| `id`          | bigint      | PK                                        |
| `user_id`     | bigint      | FK `cass_users` (`on_delete: :delete_all`) |
| `role`        | string      | `admin` \| `vendor`                       |
| `inserted_at` | utc_datetime | |

Indexes: unique `[user_id, role]` (`cass_user_roles_user_id_role_index`) and a
plain index on `[role]` for "who are the vendors/admins" lookups. A CHECK
constraint (`cass_user_roles_role_check`) restricts `role` to the two known
values, so the vocabulary is enforced independently of the application.

Design notes:

* Roles are a **join table, not a column**, so an account can hold several at
  once and granting one is a row insert rather than a `users` update. There is
  no `updated_at`: a role row is either present or not, and a re-grant after a
  revoke gets a fresh row.
* The unique index makes granting idempotent (`ON CONFLICT DO NOTHING`), and
  the same pair cannot be stored twice even by a direct database write.
* Deleting an account deletes its roles, so a revoked role cannot outlive the
  user it belonged to.
* There is deliberately **no `:customer` role**: holding no rows *is* being a
  customer, which keeps "signed in" and "is a seller" independent.

The vocabulary is owned by `Cass.Accounts.UserRole.roles/0` (`[:admin,
:vendor]`) and mirrored by the check constraint. Adding a role therefore needs
a migration, not just a code change — the same discipline the Phase 1 token
contexts use.

## Business rules (implemented in `Cass.Catalog` and `Cass.Accounts`)

### Catalog

* Slugs are globally unique across both tables and validated against the
  lowercase/hyphen regex (`Cass.Catalog.Validators.slug_format`).
* Products always belong to a category; `category_id` is never taken from
  user params (the posted id is resolved to a `%Category{}` first).
* Product ownership is a fact about the product, independent of the roles that
  grant the ability to act on it:
  * `can_create_owned_product?/1` — authenticated **and** `:vendor` or
    `:admin` (`:admin` qualifies on its own).
  * `can_manage_product?/2` — `:admin`, or `product.owner_id == scope.user.id`.
    A platform product has no owner, so only the admin branch can match it.
  * Every product mutation takes the scope first
    (`update_product/3`, `publish_product/2`, `archive_product/2`) and checks
    authorization before touching the row.
  * `list_managed_products/1` and `get_managed_product/2` filter by the caller's
    rights in SQL; anything else is `nil`, so a product that does not exist and a
    product belonging to somebody else are indistinguishable.
  * There is no transfer: ownership is set at creation and cannot be changed by
    any exposed path.
* Publishing stamps `published_at`, requires a `:draft` product **and** an
  `:active` category, and re-publishing or publishing into an archived
  category returns `{:error, changeset}`.
* Archived categories and products are immutable: updates and re-archiving
  return errors on `:base` or the offending field.
* Archiving a category does **not** cascade. Public queries filter on
  `category.status == :active`, so an active child under an archived parent
  is still individually reachable by direct URL (documented, accepted edge at
  this milestone); it is simply not surfaced through navigation rooted at
  active categories.
* `visibility` decides discoverability:
  * `public` — listed and directly fetchable (indexable).
  * `unlisted` — excluded from listings, directly fetchable, `noindex`.
  * `private` — never returned by public queries (treated as not-found).
* `published_at <= now` gates public queries (scheduled/future publishes are
  hidden until due).
* **Product types (Milestone 4)** — `product_types/0` is the closed vocabulary
  (`[:digital, :smm, :ai, :service]`), mirrored by
  `cass_products_product_type_check`. Adding or renaming a type is therefore a
  migration, not just a code change. The 2026-09-28 migration renamed the old
  values deterministically (`digital_product→digital`, `smm_service→smm`,
  `ai_tool→ai`) and added `:service`; web labels/options derive from
  `Cass.Catalog.product_types/0`.
* **Variants (Milestone 4)** — a variant is `purchasable?` when `active` and
  `stock` is not `0`. `price_cents` and `stock` are validated `>= 0`
  (`validate_number`, non-nil changes only); `config` must be a map with
  string keys or the changeset rejects it. Variant mutations are scope-first
  and reuse the product ownership check (`can_manage_product?/2`), never
  accepting a `product_id` from params.

### Orders (Milestone 5)

* **Checkout input is minimal** — each requested line is exactly
  `product_variant_id` + `quantity` (positive integers or numeric strings,
  quantity capped at `OrderItem.max_quantity/0`). Repeated ids are combined.
  Malformed requests are one generic error: "the order request is invalid".
* **The variant row is the only authority** on `price_cents`, `currency`, and
  stock; the product must be `published` (its `published_at` due) with
  `:public`/`:unlisted` visibility and in an `active` category, and the
  variant `active` and priced. Any failure surfaces as the same generic "not
  available" error, so a direct caller cannot learn *why* an item was refused.
* **The order must be single-currency** — every line's currency comes from its
  variant; mixed-currency requests are refused wholesale rather than guessed.
* **Totals are always the server-derived sum.** `total_cents` on the order and
  `OrderItem.line_total_cents/1` (`unit_price_cents * quantity`) are what an
  order's stored total must equal (`Orders.order_total_cents/1`). A request
  that carries its own `price_cents`, `total_cents`, `currency`, `user_id`, or
  names has those fields ignored.
* **Stock reservation is atomic**: `UPDATE ... SET stock = stock - qty
  WHERE id = ? AND active AND stock IS NOT NULL AND stock >= qty`. One affected
  row = reserved; zero = out of stock (order refused, nothing written).
  `stock IS NULL` (unlimited) needs no decrement. The whole check-out is one
  `Repo.transact` (the `accounts.ex` `{:ok, _}/{:error, _}` convention), so a
  failure on any line rolls back the order, its items, and every reservation.
* **Order items are immutable snapshots.** Neither schema exposes an update
  path in this milestone, and `on_delete: :restrict` keeps history around even
  if a catalog row or account is deleted.
* **Order status** starts `awaiting_payment` and is the only reachable state
  here; later milestones drive `paid → processing → completed` and the terminal
  `cancelled`/`failed`.
* **Reading is owner-or-admin.** `list_orders/1` returns every order for an
  admin and the caller's own otherwise (none for guests); `get_order/2` is
  `nil` for a foreign, malformed, or unknown id — a missing order and somebody
  else's order are deliberately indistinguishable.

### Accounts

* Registration is email + password; the address is required, must look like an
  address, and must be unique. Passwords are 12–128 characters.
* `register_user/1` always stores a `confirm` token. Confirmation consumes
  **only** that token — it never touches existing sessions, and it never signs
  anybody in.
* A session token resolves to a user only while it is unexpired. Logout deletes
  the row; a password change deletes every row for the account except the one
  that submitted the change; a password reset deletes all of them.
* Email changes are applied by token, not by the settings form: the form only
  issues a `change:<old email>` token bound to the new address, and applying it
  revokes every token issued for the previous address.
* Password resets are verified and consumed inside the transaction that stores
  the new hash, so a token cannot be used twice even if the request is replayed
  concurrently.
* Failed validation never consumes a token: a rejected reset attempt leaves the
  link usable.

### Roles and authorization

* `roles/0` is the closed vocabulary (`[:admin, :vendor]`);
  `UserRole.parse/1` accepts the atom or the string form (trimmed,
  case-insensitive) and rejects everything else, without interning atoms from
  input.
* `list_user_roles/1` returns role atoms ordered by the stored string. An empty
  list means an ordinary customer — there is no implicit `:customer`.
* `grant_user_role/2` and `revoke_user_role/2` are both idempotent and both
  reject a role outside the vocabulary (the changeset rejects it; the check
  constraint rejects it independently). The account a role is written against is
  the `%User{}` passed to the function — never a parameter.
* `user_has_role?/2` accepts either role form and is `false` for anything
  outside the vocabulary.
* Roles are read from this table whenever a `Cass.Accounts.Scope` is built, so a
  revoke takes effect on the next request or LiveView mount rather than when a
  session expires.
* There is no self-service grant path in this phase: the only way to obtain a
  role is `mix cass.accounts.create_admin` or application code calling the
  context. No HTTP route grants roles.

## Planned schema (roadmap)

* ~~`orders`, `order_items` — checkout and fulfillment state machine.~~
  Implemented in Milestone 5 (snapshot items, atomic stock reservation,
  lifecycle vocabulary); payment capture and fulfillment *transitions* arrive
  with the Payments milestone.
* `downloads` / `entitlements` — digital product access grants.
* Vendor onboarding (the `vendor` profile/business columns). Roles already exist
  (`cass_user_roles`) and product ownership exists (`cass_products.owner_id`), so
  onboarding has to add neither a role system nor an ownership column.
* **Ownership transfer** is deliberately not planned as a column change. When it
  is designed, the `on_delete: :restrict` FK is the forcing function: deleting an
  account that owns products must be refused or explicitly resolved first.
* An account-deletion or credential-history table, if a later hardening phase
  needs one.
* An account-deletion or credential-history table, if a later hardening phase
  needs one.

## Design decisions

* **Money** is stored as integer minor units (`price_cents`, `total_cents`,
  plain `integer`, no floats), defaulting to `USD`; pricing lives on
  `cass_product_variants` so `cass_order_items` can snapshot a variant's price
  at check-out, and the order total is *always* the server-derived sum of line
  totals (`unit_price_cents * quantity`).
* **Orders refuse destructive deletes.** Both order/item FKs are
  `on_delete: :restrict`, matching the catalog/sellers rule: deleting an
  account that has ordered, or a variant that has been purchased, is refused by
  the database rather than silently losing history.
* **The `:base` refusal is the only error a caller sees.** Just as with
  catalog authorization, checkout reports "the order request is invalid", "an
  item … not available", or "out of stock" without distinguishing *which* item
  or *why*, so a direct POST cannot probe the catalog through the orders API.
* **Snapshot-only order items.** Names, SKU, price, currency, quantity, and
  `metadata` (the variant's `config`) are copied at checkout and never
  re-derived, so catalog edits cannot silently rewrite a receipt.
* **Soft deletion** is avoided in favor of `status`/`archived_at` so history
  stays intact; archived rows remain queryable by the context.
* **Timestamps** use `:utc_datetime` per project convention (with the
  truncation rule above).
* The marketplace is **single-schema** (one database); multi-tenancy is
  handled at the data level only when sellers are added.