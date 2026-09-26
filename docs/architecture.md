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
    `/catalog/products/:slug`)
  * `scope "/api/v1", CassWeb.Api.V1` — JSON API (currently only health)

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

* `test/cass_web` — web/controller/liveview tests (ConnCase).
* `test/cass` — context tests backed by a real PostgreSQL database (DataCase).
* The `precommit` alias runs formatter, compile with warnings as errors,
  `deps.unlock --unused`, and the full test suite.
* CI (`/.github/workflows/ci.yml`) replays the same checks against a fresh
  PostgreSQL service on every push.