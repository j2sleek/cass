defmodule Cass.Repo.Migrations.CreateAnalyticsEvents do
  use Ecto.Migration

  # The append-only event stream that powers `Cass.Analytics` and the admin
  # insights dashboard. It is deliberately one wide, generic table rather than a
  # table per event type: event *meaning* lives in `name` and `metadata`, so a new
  # instrumented action needs no migration.
  #
  # Two identity columns, both optional:
  #
  #   * `visitor_id` — an anonymous id minted by the page-view plug and kept in
  #     the signed session. It lets us count unique visitors without a login.
  #   * `user_id` — the signed-in account, when there is one. `nilify_all` means
  #     deleting an account never deletes or orphans its analytics history.
  #
  # `subject_type` / `subject_id` name the thing an event is *about* (a product,
  # an order), kept as a loose pair so analytics stays decoupled from the
  # business schemas it observes.
  def change do
    create table(:cass_analytics_events) do
      add :name, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :visitor_id, :string
      add :user_id, references(:cass_users, on_delete: :nilify_all)
      add :path, :string
      add :referrer, :string
      add :user_agent, :string
      add :subject_type, :string
      add :subject_id, :string
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:cass_analytics_events, [:occurred_at])
    create index(:cass_analytics_events, [:name, :occurred_at])
    create index(:cass_analytics_events, [:visitor_id, :occurred_at])
    create index(:cass_analytics_events, [:user_id])
    create index(:cass_analytics_events, [:subject_type, :subject_id])
  end
end
