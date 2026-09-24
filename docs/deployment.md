# Deployment

## Production target

The canonical deployment for Cass is a managed Phoenix release:

* **Runtime**: a Linux amd64/arm64 VM or container running an Elixir/OTP
  release.
* **Reverse proxy**: a TLS-terminating reverse proxy in front of Bandit
  (standard 4000/443 wiring; `phx.gen.release` assets).
* **Database**: a managed PostgreSQL 16+ instance (RDS/Cloud SQL/Neon or a
  replicated VM). Cass connects with a single privileged release user; never
  use the postgres superuser from the app.
* **Config**: `MIX_ENV=prod`, `SECRET_KEY_BASE`, and database `DATABASE_URL`
  passed through `config/runtime.exs`. Start with `bin/cass start`.

### Environment variables

| Variable                | Purpose                                   |
| ----------------------- | ----------------------------------------- |
| `SECRET_KEY_BASE`       | Phoenix session/encryption key (required) |
| `DATABASE_URL`          | Ecto Postgres URL with credentials        |
| `PHX_HOST` / `PHX_PORT` | Public host and 0.0.0.0 bind port         |
| `POOL_SIZE`, `QUEUE_TARGET` | Connection pool and request tuning    |

## Local development environment (this machine)

The current dev box is an **aarch64 Ubuntu chroot on a Linux host that exposes
no SysV IPC and has no systemd**. PostgreSQL 18 is installed from distro
packages and is started manually.

### Why the shared-memory shim exists

PostgreSQL calls `shmget(2)` even with `shared_memory_type = mmap` — it must
probe a 56-byte token segment on startup. The Android-based kernel compiled
with `CONFIG_MEMFD_CREATE=y` but `CONFIG_SYSVIPC=n`, so `shmget` returns
`ENOSYS`. A tiny compliance shim provides `shmget/shmat/shmdt/shmctl` on top
of `memfd_create` + `mmap`:

* source: `/usr/local/src/sysv-shm/sysv_shm.c`
* binary: `/usr/local/lib/sysv_shm.so`
* it is injected for every PostgreSQL process via the cluster's environment
  file, `/etc/postgresql/18/main/environment`:

```text
LD_PRELOAD='/usr/local/lib/sysv_shm.so'
```

The shim is **not** required on normal servers (RDS, VMs with IPC) and is an
artifact of this specific dev box only.

### Managing the local cluster

```bash
pg_ctlcluster 18 main start    # start
pg_lsclusters                  # status (expect "online", port 5432)
pg_ctlcluster 18 main stop     # stop
```

The cluster binds to IPv4 `127.0.0.1:5432` plus the Unix socket
`/var/run/postgresql/.s.PGSQL.5432`. Auth: `peer` on Unix socket (local OS
user must match the PG role), `scram-sha-256` over TCP. The `postgres` role
password is set for device convenience; set role passwords in
`config/<env>.exs` / `DATABASE_URL`.

Postgres config lives in the data directory
(`/var/lib/postgresql/18/main/postgresql.conf`) with
`shared_memory_type = mmap` and `dynamic_shared_memory_type = mmap`;
`/etc/postgresql/18/main/{postgresql.conf,pg_hba.conf,pg_ident.conf}` are
symlinked to it.

### Committing and CI

* Never commit directly; run `mix precommit` and review the diff first.
* CI runs on GitHub Actions with a fresh PostgreSQL service container, so the
  shim quirks above are invisible to CI.

## Not in scope for Milestone 1

* Payment processing and PCI/DSS scope (later milestone)
* Physical product shipping/inventory (later milestone)
* Live AI provider integration (via Nexus AI Gateway, later milestone)
* Autoscaling/multi-region topology (single unit until load demands more)