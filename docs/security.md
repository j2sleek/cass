# Security

Security posture for Cass. It will grow as accounts, payments, and AI
features land.

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

* CSRF: Phoenix default token handling for browser forms.
* Session-only cookies; no sensitive data persisted client-side.
* SQL: all queries go through Ecto with parameter binding (no string
  interpolation into SQL).
* HTML is escaped by default in HEEx templates.
* Dependency footprint is minimized; `deps.unlock --unused` runs in CI to
  catch orphaned packages.

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

Any committed secret, or any report of the health endpoint leaking
configuration, is a P0. Rotate the credential, revoke exposure, and add a
regression test.