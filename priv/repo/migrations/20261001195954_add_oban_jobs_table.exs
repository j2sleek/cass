defmodule Cass.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  # Oban's own job table, backing the Milestone 12 fulfillment queue.
  #
  # This is the entire database footprint of the asynchronous delivery
  # milestone: the delivery state machine already lives in `cass_fulfillments`
  # and needs no new domain columns, so the queue is the only thing added. Jobs
  # are inserted inside the payment transaction that marks an order paid, which
  # makes "the capture committed but the delivery was never queued" an
  # unreachable state rather than something a reconciliation pass has to repair.
  #
  # Job payloads carry an opaque fulfillment id and nothing else — no prompts,
  # credentials, or customer data ever reach this table. See docs/security.md.
  #
  # `Oban.Migrations.up/0` installs the table, its indexes, and `oban_peers`.
  #
  # Note that it installs **no unique index** on `oban_jobs`. Enqueue-on-conflict
  # for a `unique:` job is not enforced by an index in Oban 2.x: the basic engine
  # takes a transaction-scoped Postgres advisory lock keyed on the unique fields,
  # then SELECTs for a matching job in the blocking states, and reports
  # `conflict?: true` if it finds one. That is why the recovery sweep can rely on
  # a duplicate reclaim collapsing rather than on a database constraint.
  def up, do: Oban.Migrations.up()

  def down, do: Oban.Migrations.down()
end
