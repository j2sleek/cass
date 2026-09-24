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

* `lib/cass/**` holds **contexts** (e.g. `Cass.Health`). Contexts own data
  access and business rules; they never know about the web layer.
* `lib/cass_web/**` holds the **web layer**: controllers, LiveViews,
  components, and the router. Web code calls context functions; contexts never
  import from `CassWeb`.
* Templates use the shared components in `CassWeb.CoreComponents` and the
  layouts in `CassWeb.Layouts`. Storefront pages are server-rendered
  controllers for SEO; interactive surfaces will use LiveView.
* Routes group concerns in the router:
  * `scope "/", CassWeb` — public browser pages
  * `scope "/api/v1", CassWeb.Api.V1` — JSON API (currently only health)

## Rendering

* Public pages render through `root.html.heex`, which ships full SEO metadata
  (title, description, canonical URL, Open Graph, Twitter card, robots) and
  JSON-LD structured data. `PageController` assigns `page_title`,
  `meta_description`, and `canonical_url` per page.
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

* `test/cass_web` — web/controller/liveview tests (ConnCase).
* `test/cass` — context tests backed by a real PostgreSQL database (DataCase).
* The `precommit` alias runs formatter, compile with warnings as errors,
  `deps.unlock --unused`, and the full test suite.
* CI (`/.github/workflows/ci.yml`) replays the same checks against a fresh
  PostgreSQL service on every push.