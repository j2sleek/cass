# Analytics and Insights

Analytics is a **core subsystem**, not an afterthought: the marketplace measures
its own traffic, funnel, and unmet demand, and surfaces that to admins so the
roadmap is driven by real behaviour rather than guesswork.

The whole subsystem is `Cass.Analytics`, its append-only table
`cass_analytics_events`, the buffered writer, one browser plug, and the
admin-only `CassWeb.InsightsLive` dashboard.

## Design rules

1. **Analytics is an observer, never a participant.** Nothing in the platform
   reads analytics to make a business decision. Contexts call
   `Cass.Analytics.track/2`; the read path is only the insights dashboard.
   `subject_type` / `subject_id` are loose strings precisely so analytics stays
   decoupled from the schemas it observes.
2. **Recording never slows or breaks a request.** `track/2` builds a plain map
   and hands it to `Cass.Analytics.Writer`, which flushes batches to Postgres
   out of band. `track/2` rescues every error and logs it — a lost event must
   never cost a customer a page or an order.
3. **Privacy by construction.** An event carries at most an anonymous visitor
   id, an optional user id, the request path/referrer/user agent (truncated),
   and a small JSON metadata map. No secrets, no free-form form input, no
   password-adjacent data.
4. **No schema churn per event.** One wide table; a new instrumented action
   needs no migration.

## Data model

`cass_analytics_events` is append-only (no `updated_at`):

| Column         | Type              | Notes                                        |
| -------------- | ----------------- | -------------------------------------------- |
| `id`           | bigint            | PK                                           |
| `name`         | string            | Event identifier, e.g. `page_view`           |
| `occurred_at`  | utc_datetime_usec | When it happened (server clock)              |
| `visitor_id`   | string            | Anonymous UUID from the signed session       |
| `user_id`      | bigint FK         | `cass_users`, `on_delete: :nilify_all`       |
| `path`         | string            | Request path (where relevant)                |
| `referrer`     | string            | Truncated `Referer` header                   |
| `user_agent`   | string            | Truncated `User-Agent` header                |
| `subject_type` | string            | What the event is *about*, e.g. `product`    |
| `subject_id`   | string            | Id of that thing (kept as text)              |
| `metadata`     | map (jsonb)       | Event-specific, JSON-encodable values only   |
| `inserted_at`  | utc_datetime_usec | Row write time                               |

Indexes: `occurred_at`; `(name, occurred_at)`; `(visitor_id, occurred_at)`;
`user_id`; `(subject_type, subject_id)`.

## Write path

```
LiveView / context ── Cass.Analytics.track/2 ──▶ Cass.Analytics.Writer (buffer)
                                                      │ every @batch_size or @flush_interval
                                                      ▼
                                         Repo.insert_all(Cass.Analytics.Event, batch)
```

* `Cass.Analytics.track(name, attrs)` normalizes and caps every value, then
  either casts to the writer (normal running) or inserts inline (test; see
  below). It returns `:ok` and never raises.
* `Cass.Analytics.Writer` is a `GenServer` started from `Cass.Application`. It
  flushes on size (`200`) or time (`2_000ms`). A crash can lose buffered
  events, which is an accepted trade-off for a measurement stream.
* `CassWeb.Plugs.TrackPageView` (in the `:browser` pipeline) records one
  `page_view` per HTML `GET` document request and mints the anonymous
  `cass_visitor_id` into the signed session. It never touches the session on
  non-tracked requests.
* `CassWeb.LiveAnalytics.track/3` is the socket-aware shim used by LiveViews;
  it pulls `visitor_id` and `user_id` off the socket.

## Event vocabulary

| `name`           | Emitted by                          | Notable metadata                              |
| ---------------- | ----------------------------------- | --------------------------------------------- |
| `page_view`      | `CassWeb.Plugs.TrackPageView`       | `method`                                      |
| `search`         | `CassWeb.CatalogLive`               | `query`, `result_count`, `sort`               |
| `filter`         | `CassWeb.CatalogLive`               | `types`, `in_stock`, `min_price_cents`, `max_price_cents`, `result_count`, `sort` |
| `product_view`   | `CassWeb.ProductLive`               | `title`, `product_type`, `category`           |
| `order_created`  | `Cass.Orders.create_order/2`        | `total_cents`, `currency`, `item_count`       |
| `order_paid`     | `Cass.Orders.mark_order_paid/1`     | `total_cents`, `currency`                     |
| `ai_run`         | `Cass.Ai`                           | `status`, `model`, `prompt_chars`             |

`order_created` is recorded only on a successful order; `order_paid` only on the
real `:awaiting_payment → :paid` transition (a repeated webhook is idempotent
and does not double-count).

## Read path: `/insights`

`CassWeb.InsightsLive` is an **admin-only** (`require_admin`), `noindex` page. A
window selector (7/30/90 days) drives `Cass.Analytics` aggregate queries:

* `summary/1` — page views, unique visitors, product views, searches, orders
  created/paid, AI runs.
* `page_views_over_time/1` — page views per calendar day (chart).
* `top_paths/1` — most-viewed pages.
* `top_products/1` — most-viewed products.
* `top_searches/1` — most frequent searches.
* `searches_without_results/1` — **the product-idea feed**: searches that
  returned nothing, i.e. demand the catalog does not currently meet.

The dashboard is rendered entirely server-side with hand-rolled Tailwind; there
is no charting dependency.

## Configuration and testing

```
# config/config.exs
config :cass, Cass.Analytics, writer: true

# config/test.exs
config :cass, Cass.Analytics, writer: false
```

In tests the writer is disabled, so `track/2` inserts synchronously inside the
Ecto sandbox transaction and rows roll back with the test — no long-lived
process touches the connection pool.

Coverage: `test/cass/analytics_test.exs` (write/read path),
`test/cass_web/plugs/track_page_view_test.exs` (page views, visitor id, user
attribution), `test/cass_web/live/analytics_instrumentation_test.exs` (search /
product view), and `test/cass_web/live/insights_live_test.exs` (authorization and
dashboard data).

## Extending

To instrument a new action, call `Cass.Analytics.track/2` (or
`CassWeb.LiveAnalytics.track/3` from a LiveView) with a new `name`. If the event
feeds a dashboard panel, add a focused query to `Cass.Analytics` and a section to
`InsightsLive`. No migration is required unless you need a new first-class column
for indexing/filtering.