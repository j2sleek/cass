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
  constraints, scope resolution).
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
