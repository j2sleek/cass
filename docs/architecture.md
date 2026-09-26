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
  * `scope "/api/v1", CassWeb.Api.V1` — JSON API (currently only health)

## Accounts and current scope

* `Cass.Accounts` owns `cass_users`, `cass_users_tokens`, registration,
  credential lookup, confirmation, sessions, email changes, and password
  resets. It has no knowledge of the web layer.
* `CassWeb.UserAuth` is the single seam between the session and the request. It
  provides a browser pipeline plug, a LiveView `on_mount` hook, and a
  LiveView-safe guard:
  * `fetch_current_scope_for_user/2` (plug) and `mount_current_scope/1`
    (`on_mount`) resolve the session token — from the signed session, or from
    the signed remember-me cookie — and assign
    `current_scope: Cass.Accounts.Scope.for_user(user)`. A guest scope is
    `nil`.
  * `require_authenticated_user/2` (plug) and `on_mount(:require_authenticated)`
    gate signed-in-only routes. A guest GET is redirected to `/users/log-in`
    with the destination remembered in the session; non-GET requests are not
    remembered.
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
* The account model is deliberately minimal in this phase (no roles, ownership,
  or vendor flags). `Cass.Accounts.Scope` carrying only `user` is the seam
  where a later phase widens it.

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
  `live/user_*_live_test.exs` per auth page.
* `test/cass` — context tests backed by a real PostgreSQL database (DataCase).
* The `precommit` alias runs formatter, compile with warnings as errors,
  `deps.unlock --unused`, and the full test suite.
* CI (`/.github/workflows/ci.yml`) replays the same checks against a fresh
  PostgreSQL service on every push.
