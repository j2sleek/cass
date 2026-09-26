# Data Model

Current status: **Milestone 2 — catalog foundation is implemented.** Two domain
tables exist (`cass_categories`, `cass_products`), managed by the
`Cass.Catalog` context. Accounts, orders, and AI tool runtime data arrive in
later milestones.

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
| `product_type`| enum        | `digital_product` \| `smm_service` \| `ai_tool` |
| `status`      | enum        | `draft` \| `published` \| `archived`      |
| `visibility`  | enum        | `public` \| `unlisted` \| `private`       |
| `short_description` | string | Optional, used on cards / previews |
| `description` | text        | Optional, plain text                      |
| `seo_title`   | string      | Optional                                  |
| `seo_description` | string | Optional                                  |
| `canonical_url` | string    | Optional/reserved alternate canonical, validated as absolute http(s) |
| `published_at`| utc_datetime | Null until publish; public queries require `published_at <= now` (`nil` = not due) |
| `inserted_at` / `updated_at` | utc_datetime | |

Index: unique `slug`. CHECK constraints enforce the enum domains
(`product_type`, `status`, `visibility`); the publish-only-drafts and
publish-into-active-category guards live in the `Cass.Catalog` context layer.

### Timestamps and `:utc_datetime`

`:utc_datetime` columns reject microsecond precision at write time, so all
code must truncate: `DateTime.utc_now() |> DateTime.truncate(:second)`
(encapsulated as `Cass.Catalog.utc_now/0`). Test setups reuse the same
function to stamp `published_at` for scheduling tests.

## Business rules (implemented in `Cass.Catalog`)

* Slugs are globally unique across both tables and validated against the
  lowercase/hyphen regex (`Cass.Catalog.Validators.slug_format`).
* Products always belong to a category; `category_id` is never taken from
  user params.
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

## Planned schema (roadmap)

* `users`, `sessions` — accounts and password auth.
* `orders`, `order_items` — checkout and fulfillment state machine.
* `downloads` / `entitlements` — digital product access grants.
* `prices` as integer minor units (`price_cents`, plain `integer`, no
  floats), currency defaulting to `USD`.
* `seller_id` FK on products when vendor onboarding lands.

## Design decisions

* **Money** (later) is stored as integer minor units to avoid rounding bugs.
* **Soft deletion** is avoided in favor of `status`/`archived_at` so history
  stays intact; archived rows remain queryable by the context.
* **Timestamps** use `:utc_datetime` per project convention (with the
  truncation rule above).
* The marketplace is **single-schema** (one database); multi-tenancy is
  handled at the data level only when sellers are added.