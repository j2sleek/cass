defmodule Cass.Analytics do
  @moduledoc """
  The write path and the read queries for product and UX analytics.

  This context is the *one* place the platform records what happened, and the
  one place insights are read from. Two ideas shape it:

  * **Never slow the request, never break it.** `track/2` builds a plain map and
    hands it to `Cass.Analytics.Writer`, a buffered process that flushes batches
    to Postgres out of band. If the database is down, if a metadata value cannot
    be encoded, or if the writer is not running, the caller is unaffected: a lost
    analytics event must never cost a customer a page or an order.
  * **Analytics is an observer, not a participant.** It depends on the catalog,
    orders, payments, and AI only in the sense that they call `track/2`; nothing
    in the platform reads analytics to make a business decision. `subject_type` /
    `subject_id` are loose strings for exactly this reason.

  ## The event vocabulary

  | name            | emitted by                              | notable metadata |
  | --------------- | --------------------------------------- | ---------------- |
  | `page_view`     | `CassWeb.Plugs.TrackPageView`           | `method`         |
  | `search`        | `CassWeb.CatalogLive`                   | `query`, `result_count`, `sort` |
  | `product_view`  | `CassWeb.ProductLive`                   | `title`, `product_type` |
  | `order_created` | `Cass.Orders.create_order/2`            | `total_cents`, `currency`, `item_count` |
  | `order_paid`    | `Cass.Orders.mark_order_paid/1`         | `total_cents`, `currency` |
  | `ai_run`        | `Cass.Ai`                               | `model`, `status` |

  ## Writing

      Cass.Analytics.track("product_view", %{
        visitor_id: "…",
        subject_type: "product",
        subject_id: product.id,
        metadata: %{"title" => product.name}
      })

  ## Reading (the insights dashboard)

  `summary/1`, `page_views_over_time/1`, `top_paths/1`, `top_products/1`,
  `top_searches/1`, and `searches_without_results/1` are read-only aggregations
  over the events in a rolling day window. The last two are the "what should we
  sell next?" signal: what people searched for, and what they searched for that
  we could not answer.
  """
  import Ecto.Query
  require Logger

  alias Cass.Analytics.Event
  alias Cass.Analytics.Writer
  alias Cass.Repo

  @default_window_days 30
  @max_window_days 365
  @default_limit 10
  @max_limit 100
  @default_list_limit 100

  @doc """
  Records one domain event. This is the only public write entry point.

  It never raises into the caller: any failure is logged and swallowed, because
  analytics must never be able to break a request or a purchase.

  `attrs` is a map (or keyword list) with optional `:visitor_id`, `:user_id`,
  `:path`, `:referrer`, `:user_agent`, `:subject_type`, `:subject_id`,
  `:occurred_at`, and `:metadata`.
  """
  @spec track(String.t(), map() | keyword()) :: :ok
  def track(name, attrs \\ %{}) when is_binary(name) do
    event = build_event(name, attrs)

    if writer_enabled?() do
      Writer.record(event)
    else
      record_many([event])
    end

    :ok
  rescue
    error ->
      Logger.warning("[analytics] dropped #{inspect(name)} event: #{Exception.message(error)}")

      :ok
  end

  @doc """
  Inserts a batch of already-built event maps.

  Exposed for `Cass.Analytics.Writer`; most callers want `track/2` instead.
  """
  @spec record_many([map()]) :: {non_neg_integer(), nil} | :error
  def record_many(events) when is_list(events) do
    Repo.insert_all(Event, events)
  rescue
    error ->
      Logger.error(
        "[analytics] failed to insert #{length(events)} event(s): #{Exception.message(error)}"
      )

      :error
  end

  @doc "Returns a coarse dashboard summary for the rolling day window."
  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    since = since(opts)

    %{
      page_views: count_named(since, "page_view"),
      product_views: count_named(since, "product_view"),
      searches: count_named(since, "search"),
      orders_created: count_named(since, "order_created"),
      orders_paid: count_named(since, "order_paid"),
      ai_runs: count_named(since, "ai_run"),
      unique_visitors: unique_visitors(since)
    }
  end

  @doc "Page views per calendar day, oldest first, as `{naive_datetime, count}`."
  @spec page_views_over_time(keyword()) :: [{NaiveDateTime.t(), non_neg_integer()}]
  def page_views_over_time(opts \\ []) do
    since = since(opts)

    Repo.all(
      from e in Event,
        where: e.occurred_at >= ^since and e.name == "page_view",
        group_by: fragment("date_trunc('day', ?)", e.occurred_at),
        order_by: [asc: fragment("date_trunc('day', ?)", e.occurred_at)],
        select: {fragment("date_trunc('day', ?)", e.occurred_at), count(e.id)}
    )
  end

  @doc "Most-viewed request paths as `{path, count}`."
  @spec top_paths(keyword()) :: [{String.t(), non_neg_integer()}]
  def top_paths(opts \\ []) do
    since = since(opts)
    limit = limit(opts)

    Repo.all(
      from e in Event,
        where: e.occurred_at >= ^since and e.name == "page_view" and not is_nil(e.path),
        group_by: e.path,
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: {e.path, count(e.id)}
    )
  end

  @doc "Most-viewed products as `{subject_id, title, count}`."
  @spec top_products(keyword()) :: [{String.t(), String.t() | nil, non_neg_integer()}]
  def top_products(opts \\ []) do
    since = since(opts)
    limit = limit(opts)

    Repo.all(
      from e in Event,
        where: e.occurred_at >= ^since and e.name == "product_view" and not is_nil(e.subject_id),
        group_by: [e.subject_id, fragment("?->>'title'", e.metadata)],
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: {e.subject_id, fragment("?->>'title'", e.metadata), count(e.id)}
    )
  end

  @doc "Most frequent non-empty searches as `{query, count}`."
  @spec top_searches(keyword()) :: [{String.t(), non_neg_integer()}]
  def top_searches(opts \\ []) do
    since = since(opts)
    limit = limit(opts)

    Repo.all(
      from e in Event,
        where: e.occurred_at >= ^since and e.name == "search",
        where: fragment("coalesce(?->>'query', '') <> ''", e.metadata),
        group_by: fragment("?->>'query'", e.metadata),
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: {fragment("?->>'query'", e.metadata), count(e.id)}
    )
  end

  @doc """
  Searches that returned nothing, as `{query, count}`.

  This is the product-idea feed: demand the catalog does not currently meet.
  """
  @spec searches_without_results(keyword()) :: [{String.t(), non_neg_integer()}]
  def searches_without_results(opts \\ []) do
    since = since(opts)
    limit = limit(opts)

    Repo.all(
      from e in Event,
        where: e.occurred_at >= ^since and e.name == "search",
        where: fragment("coalesce(?->>'query', '') <> ''", e.metadata),
        where: fragment("coalesce((?->>'result_count')::int, 0) = 0", e.metadata),
        group_by: fragment("?->>'query'", e.metadata),
        order_by: [desc: count(e.id)],
        limit: ^limit,
        select: {fragment("?->>'query'", e.metadata), count(e.id)}
    )
  end

  @doc "Lists events newest-first, optionally filtered by `:name` and `:visitor_id`."
  @spec list_events(keyword()) :: [Event.t()]
  def list_events(opts \\ []) do
    list_limit = normalize_int(Keyword.get(opts, :limit), @default_list_limit)

    query =
      from e in Event,
        order_by: [desc: e.occurred_at, desc: e.id],
        limit: ^list_limit

    query = if name = opts[:name], do: where(query, [e], e.name == ^name), else: query

    query =
      if visitor = opts[:visitor_id],
        do: where(query, [e], e.visitor_id == ^visitor),
        else: query

    Repo.all(query)
  end

  ## Building the row

  defp build_event(name, attrs) do
    attrs = Map.new(attrs)
    now = DateTime.utc_now()

    %{
      name: name,
      occurred_at: Map.get(attrs, :occurred_at, now),
      visitor_id: stringify(attrs[:visitor_id]),
      user_id: user_id(attrs[:user_id]),
      path: truncate(attrs[:path], 512),
      referrer: truncate(attrs[:referrer], 512),
      user_agent: truncate(attrs[:user_agent], 512),
      subject_type: stringify(attrs[:subject_type]),
      subject_id: stringify(attrs[:subject_id]),
      metadata: normalize_metadata(attrs[:metadata]),
      inserted_at: now
    }
  end

  defp user_id(%{id: id}) when is_integer(id), do: id
  defp user_id(id) when is_integer(id), do: id
  defp user_id(_other), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(_other), do: nil

  defp truncate(nil, _max), do: nil
  defp truncate(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp truncate(_other, _max), do: nil

  defp normalize_metadata(metadata) when is_map(metadata) do
    for {key, value} <- metadata, not is_nil(value), into: %{} do
      {to_string(key), normalize_value(value)}
    end
  end

  defp normalize_metadata(_other), do: %{}

  defp normalize_value(nil), do: nil
  defp normalize_value(value) when is_binary(value), do: value

  defp normalize_value(value)
       when is_integer(value) or is_float(value) or is_boolean(value),
       do: value

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: inspect(value)

  ## Windows and limits

  defp since(opts) do
    days =
      opts
      |> Keyword.get(:days, @default_window_days)
      |> normalize_int(@default_window_days)
      |> max(1)
      |> min(@max_window_days)

    DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
  end

  defp limit(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> normalize_int(@default_limit)
    |> max(1)
    |> min(@max_limit)
  end

  defp normalize_int(value, _default) when is_integer(value), do: value

  defp normalize_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp normalize_int(_value, default), do: default

  defp count_named(since, name) do
    Repo.one(
      from e in Event,
        where: e.occurred_at >= ^since and e.name == ^name,
        select: count(e.id)
    )
  end

  defp unique_visitors(since) do
    Repo.one(
      from e in Event,
        where: e.occurred_at >= ^since and not is_nil(e.visitor_id),
        select: count(e.visitor_id, :distinct)
    )
  end

  defp writer_enabled? do
    Application.get_env(:cass, __MODULE__, [])
    |> Keyword.get(:writer, true)
  end
end
