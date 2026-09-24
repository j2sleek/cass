# Data Model

Current status: **no domain tables yet.** Milestone 1 ships the application
scaffold, migrations infrastructure (Ecto/PostgreSQL), and a running database
(`cass_dev`, `cass_test`), but the only database interaction so far is the
health probe (`SELECT 1`).

## Naming and conventions

* Ecto schemas live in `lib/cass/<domain>/` (e.g.
  `Cass.Catalog`, `Cass.Commerce` when created).
* Fields use `:string` by default (`Ecto.Schema` guideline); use
  `:utc_datetime` for time fields to match the generator setting.
* Foreign keys (`*_id`) are **not** cast from user params; they are set
  programmatically during create to enforce security rules.
* Migrations are generated with `mix ecto.gen.migration <name>` so timestamps
  and file layout follow convention.

## Planned schema (roadmap)

These models are the target for later milestones and are shown for design
purposes only — none exist yet.

### Catalog

* `categories` — `id`, `slug` (unique), `name`, `description`,
  `position`, timestamps
* `products` — `id`, `category_id` (FK), `slug` (unique), `type`
  (digital | service | ai_tool), `name`, `description`, `price_cents`,
  `currency` (defaults `USD`), `status` (draft | active | archived),
  `seller_id` (FK, null) , timestamps

### Accounts & orders (later)

* `users` — `id`, `email` (unique), `hashed_password`, `role`, timestamps
* `orders` / `order_items` — checkout and fulfillment state machine
* `downloads` / `entitlements` — track digital product access grants

## Design decisions

* **Money** is stored as integer minor units (`price_cents`, plain
  `integer`, no floats) to avoid rounding bugs.
* **Soft deletion** is avoided in favor of `status`/`archived_at` so history
  and invoices stay intact.
* **Timestamps** use `:utc_datetime` (`timestamp with time zone`-agnostic)
  per project convention.
* The marketplace is **single-schema** (one database) for Milestone 1;
  multi-tenancy is handled at the data level only when sellers are added.