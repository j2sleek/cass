# Security

Current status: **Milestone 3 Phase 2 — accounts, authentication, and the
`:admin`/`:vendor` role foundation are implemented** (see
[Accounts security](#accounts-and-authentication-milestone-3-phase-1) and
[Roles and authorization](#roles-and-authorization-milestone-3-phase-2)).
Catalog controls (below) still apply unchanged.

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
* **Ownership is still not modeled.** `:vendor` marks an account as a seller but
  grants no rights over any product; there is no `seller_id` yet, so no
  vendor-scoped authorization can be (mis)written against this phase.

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
* Foreign keys (`category_id`, `parent_id`) are never accepted from params;
  they are set programmatically, and create/update guard against archived
  parents/categories.
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
