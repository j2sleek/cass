defmodule Cass.Analytics.Event do
  @moduledoc """
  One append-only record of something that happened on the platform.

  An event is intentionally generic: `name` is a short verb-ish identifier
  (`"page_view"`, `"product_view"`, `"search"`, `"order_created"`, ...) and
  everything specific to that name lives in `metadata`. This is what lets the
  platform add a new instrumented action without a schema migration.

  ## Privacy by construction

  An event is never a place to put sensitive data. It carries at most:

    * an anonymous `visitor_id` (a random UUID kept in the signed session),
    * an optional `user_id` for a signed-in account,
    * the request `path`, `referrer`, and `user_agent` (truncated), and
    * a small, JSON-encodable `metadata` map.

  Nothing secret, no free-form form input, and no secrets/hashes are ever
  written here; see `Cass.Analytics` for the single write path.

  The table is append-only: there is no `updated_at`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: true}
  schema "cass_analytics_events" do
    field :name, :string
    field :occurred_at, :utc_datetime_usec
    field :visitor_id, :string
    field :user_id, :id
    field :path, :string
    field :referrer, :string
    field :user_agent, :string
    field :subject_type, :string
    field :subject_id, :string
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime_usec
  end

  @required ~w(name occurred_at)a
  @optional ~w(visitor_id user_id path referrer user_agent subject_type subject_id metadata inserted_at)a

  @doc """
  Casts and validates an event.

  Used by tests and by any caller that wants a changeset; the hot write path in
  `Cass.Analytics` builds plain maps and uses `insert_all/3` for throughput.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(event \\ %__MODULE__{}, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 64)
    |> validate_length(:visitor_id, max: 128)
    |> validate_length(:path, max: 512)
    |> validate_length(:referrer, max: 512)
    |> validate_length(:user_agent, max: 512)
    |> validate_length(:subject_type, max: 64)
    |> validate_length(:subject_id, max: 128)
  end
end
