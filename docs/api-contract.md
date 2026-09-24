# API Contract

Public API lives under `/api/v1`. All responses are JSON
(`Content-Type: application/json; charset=utf-8`). There is no authentication
on the health endpoint; future write endpoints will require authentication
(bearer tokens) and authorization.

## Endpoints

### `GET /api/v1/health`

Read-only health check. No secrets or connection details are ever returned.

**200 OK** when the application is serving and the database responds:

```json
{
  "status": "ok",
  "service": "cass",
  "version": "0.1.0",
  "environment": "dev",
  "database": { "status": "up" },
  "uptime_seconds": 123,
  "timestamp": "2026-09-24T18:25:00Z"
}
```

**503 Service Unavailable** when the application is up but the database does
not respond within 2 seconds; the body keeps the same shape with
`status: "degraded"` and `database.status: "down"`.

### Field reference

| Field             | Type   | Description                                        |
| ----------------- | ------ | -------------------------------------------------- |
| `status`          | string | `ok` or `degraded`                                 |
| `service`         | string | Fixed identifier for this service (`cass`)         |
| `version`         | string | App version from `mix.exs`                         |
| `environment`     | string | `dev`, `test`, or `prod`                           |
| `database.status` | string | `up` or `down` (last `SELECT 1` probe)             |
| `uptime_seconds`  | int    | Seconds since the application started              |
| `timestamp`       | string | ISO-8601 UTC timestamp of the probe                |

### Error semantics

* Unknown routes return the default Phoenix 404/405 JSON error bodies.
* Unsupported methods on `/api/v1/health` return 405.
* Malformed requests never leak stack traces or connection strings.

### Versioning

This is spec version `v1`. Breaking changes require a new major prefix
(`/api/v2`) and a documented deprecation window. Additive, backward-compatible
response fields are allowed within `v1`.

### Future endpoints (not implemented)

The following surface is planned and **explicitly not live**:

* `GET /api/v1/categories` — marketplace categories
* `GET /api/v1/products` — product listings
* Payments, orders, and AI tool proxying arrive in later milestones.