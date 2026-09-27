# Cass

A unified marketplace for digital products, compliant social marketing
services, and AI-powered tools, built with Elixir, Phoenix LiveView, and
PostgreSQL.

**Status: Milestone 3 Phase 2 (accounts, authentication, and the role
foundation).** This release ships the server-rendered storefront catalog, a
complete, session-based account system (registration with emailed confirmation,
login with an optional 14-day remembered session, password reset, and account
settings), and a minimal role system: every account is a customer, and
`:admin`/`:vendor` are explicit grants read from the database on each request.
Admin/vendor areas, ownership, checkout, payments, and AI features arrive in
later milestones and are **not** available yet.

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
* **Not yet exposed** — no admin dashboard, vendor onboarding, product
  ownership, or role-management UI; the guards are in place for the phases that
  will use them, and nothing is half-protected in the meantime.

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
* **Seeds** — `mix run priv/repo/seeds.exs` loads three root categories with
  a published product each (idempotent).
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
5. Vendor onboarding and product ownership, admin dashboard, profile, and
   account deletion
6. Checkout and order flow
7. AI tools routed through the Nexus AI Gateway
8. JSON catalog API under `/api/v1` (optional, additive)

Payments, physical product fulfillment, and live AI integrations are scoped to
later milestones.

## Learn more

* Phoenix: https://www.phoenixframework.org/
* LiveView: https://hexdocs.pm/phoenix_live_view/
* Ecto: https://hexdocs.pm/ecto/
* Tailwind CSS v4: https://tailwindcss.com/