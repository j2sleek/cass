# Cass

A unified marketplace for digital products, compliant social marketing
services, and AI-powered tools, built with Elixir, Phoenix LiveView, and
PostgreSQL.

**Status: Milestone 1 (foundation).** This release ships a server-rendered
storefront shell, a public health endpoint, documentation, and continuous
integration. Catalog, checkout, payments, accounts, and AI features arrive in
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
```

## What's implemented (Milestone 1)

* **Storefront shell** — semantic, responsive, server-rendered landing page
  with SEO metadata (title, description, canonical, Open Graph, Twitter card)
  and JSON-LD structured data.
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

1. Catalog domains (products, categories) with Ecto schemas and migrations
2. Storefront catalog pages
3. Accounts and authentication
4. Checkout and order flow
5. AI tools routed through the Nexus AI Gateway

Payments, physical product fulfillment, and live AI integrations are scoped to
later milestones.

## Learn more

* Phoenix: https://www.phoenixframework.org/
* LiveView: https://hexdocs.pm/phoenix_live_view/
* Ecto: https://hexdocs.pm/ecto/
* Tailwind CSS v4: https://tailwindcss.com/