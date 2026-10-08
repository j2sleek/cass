defmodule CassWeb.InsightsLive do
  @moduledoc """
  The admin insights dashboard (`/insights`).

  A deliberately admin-only, server-rendered view of the `Cass.Analytics` event
  stream: traffic, the product funnel (view → order → paid), what buyers look at,
  what they search for, and — the part that drives the roadmap — **what they
  search for and find nothing**. That last panel is a running list of product
  ideas straight from unmet demand.

  The page is `noindex` and reads only aggregate counts; it never exposes raw
  visitor or order data beyond what an admin already has.
  """
  use CassWeb, :live_view

  alias Cass.Analytics

  @windows [7, 30, 90]
  @default_window 30

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:page_title, "Insights · CASS")
    |> assign(:meta_description, "Internal product and UX analytics for CASS.")
    |> assign(:robots, "noindex, nofollow")
    |> assign(:windows, @windows)
    |> ok()
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, normalize_days(params["days"]))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/insights"}>
      <section class="border-b border-zinc-200/70 pb-8 dark:border-white/10">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
              Insights
            </h1>
            <p class="mt-3 max-w-2xl text-base leading-7 text-zinc-600 dark:text-zinc-300">
              How the marketplace is actually used: traffic, the purchase funnel, and the
              searches that reveal what to build or stock next.
            </p>
          </div>

          <div
            id="insights-window"
            class="flex items-center gap-1 rounded-xl border border-zinc-200 bg-white p-1 dark:border-white/10 dark:bg-white/5"
          >
            <%= for window <- @windows do %>
              <.link
                patch={~p"/insights?days=#{window}"}
                id={"insights-window-#{window}"}
                class={[
                  "rounded-lg px-3 py-1.5 text-sm font-medium transition",
                  window == @days && "bg-brand-600 text-white",
                  window != @days &&
                    "text-zinc-600 hover:bg-zinc-100 hover:text-brand-700 dark:text-zinc-300 dark:hover:bg-white/5"
                ]}
              >
                {window}d
              </.link>
            <% end %>
          </div>
        </div>
      </section>

      <section class="pt-10">
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.stat_card label="Page views" value={@summary.page_views} />
          <.stat_card label="Unique visitors" value={@summary.unique_visitors} />
          <.stat_card label="Product views" value={@summary.product_views} />
          <.stat_card label="Searches" value={@summary.searches} />
          <.stat_card label="Orders created" value={@summary.orders_created} />
          <.stat_card label="Orders paid" value={@summary.orders_paid} />
          <.stat_card label="AI runs" value={@summary.ai_runs} hint="attempts, incl. refusals" />
        </div>
      </section>

      <section class="pt-10">
        <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
          Purchase funnel
        </h2>
        <div class="mt-4 grid gap-4 sm:grid-cols-3">
          <.funnel_step
            label="Product views"
            value={@summary.product_views}
            base={@summary.product_views}
          />
          <.funnel_step
            label="Orders created"
            value={@summary.orders_created}
            base={@summary.product_views}
          />
          <.funnel_step
            label="Orders paid"
            value={@summary.orders_paid}
            base={@summary.orders_created}
          />
        </div>
      </section>

      <section class="pt-10">
        <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
          Page views
        </h2>
        <div class="mt-4 rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm dark:border-white/10 dark:bg-white/5">
          <%= if @views_by_day == [] do %>
            <p class="rounded-xl border border-dashed border-zinc-200 px-4 py-8 text-center text-sm text-zinc-500 dark:border-white/10 dark:text-zinc-400">
              No page views in this window yet.
            </p>
          <% else %>
            <div class="flex h-40 items-end gap-1">
              <%= for {day, count} <- @views_by_day do %>
                <div
                  class="flex-1 rounded-t bg-brand-500/80 transition hover:bg-brand-600"
                  style={"height: #{height_pct(count, @views_max)}%"}
                  title={"#{Calendar.strftime(day, "%b %-d")}: #{delimit(count)}"}
                >
                </div>
              <% end %>
            </div>
            <div class="mt-2 flex justify-between text-xs text-zinc-400 dark:text-zinc-500">
              <span>{Calendar.strftime(datetime(List.first(@views_by_day)), "%b %-d")}</span>
              <span>{Calendar.strftime(datetime(List.last(@views_by_day)), "%b %-d")}</span>
            </div>
          <% end %>
        </div>
      </section>

      <div class="grid gap-10 pt-10 lg:grid-cols-2">
        <section>
          <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
            Top pages
          </h2>
          <div class="mt-4">
            <.bar_list rows={@top_paths} max={@paths_max} empty="No page views yet." mono />
          </div>
        </section>

        <section>
          <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
            Most viewed products
          </h2>
          <div class="mt-4">
            <.bar_list
              rows={
                Enum.map(@top_products, fn {_id, title, count} ->
                  {title || "Unknown product", count}
                end)
              }
              max={@products_max}
              empty="No product views yet."
            />
          </div>
        </section>

        <section>
          <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
            Top searches
          </h2>
          <div class="mt-4">
            <.bar_list rows={@top_searches} max={@searches_max} empty="No searches yet." />
          </div>
        </section>

        <section id="product-ideas">
          <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
            Product ideas
          </h2>
          <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
            Searches that returned nothing — demand we cannot currently meet.
          </p>
          <div class="mt-4">
            <.bar_list
              rows={@no_result_searches}
              max={@no_result_max}
              empty="No empty searches yet — catalog coverage looks good."
              accent="amber"
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :hint, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm dark:border-white/10 dark:bg-white/5">
      <span class="text-sm font-medium text-zinc-500 dark:text-zinc-400">{@label}</span>
      <span class="mt-2 block text-3xl font-bold tracking-tight text-zinc-900 dark:text-white">
        {delimit(@value)}
      </span>
      <span :if={@hint} class="mt-1 block text-xs text-zinc-400 dark:text-zinc-500">
        {@hint}
      </span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :base, :integer, required: true

  defp funnel_step(assigns) do
    ~H"""
    <div class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm dark:border-white/10 dark:bg-white/5">
      <span class="text-sm font-medium text-zinc-500 dark:text-zinc-400">{@label}</span>
      <span class="mt-2 block text-3xl font-bold tracking-tight text-zinc-900 dark:text-white">
        {delimit(@value)}
      </span>
      <span class="mt-1 block text-xs text-zinc-400 dark:text-zinc-500">
        {pct(@value, @base)}% of previous step
      </span>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :max, :integer, required: true
  attr :empty, :string, required: true
  attr :mono, :boolean, default: false
  attr :accent, :string, default: "brand"

  defp bar_list(assigns) do
    ~H"""
    <%= if @rows == [] do %>
      <p class="rounded-xl border border-dashed border-zinc-200 px-4 py-6 text-center text-sm text-zinc-500 dark:border-white/10 dark:text-zinc-400">
        {@empty}
      </p>
    <% else %>
      <ul class="space-y-3">
        <%= for {label, count} <- @rows do %>
          <li>
            <div class="flex items-baseline justify-between gap-4 text-sm">
              <span class={[
                "truncate font-medium text-zinc-700 dark:text-zinc-200",
                @mono && "font-mono text-xs"
              ]}>
                {label}
              </span>
              <span class="shrink-0 tabular-nums text-zinc-500 dark:text-zinc-400">
                {delimit(count)}
              </span>
            </div>
            <div class="mt-1.5 h-1.5 overflow-hidden rounded-full bg-zinc-100 dark:bg-white/10">
              <div
                class={[
                  "h-full rounded-full",
                  if(@accent == "amber", do: "bg-amber-500", else: "bg-brand-500")
                ]}
                style={"width: #{pct(count, @max)}%"}
              >
              </div>
            </div>
          </li>
        <% end %>
      </ul>
    <% end %>
    """
  end

  defp load(socket, days) do
    views_by_day = Analytics.page_views_over_time(days: days)
    top_paths = Analytics.top_paths(days: days, limit: 8)
    top_products = Analytics.top_products(days: days, limit: 8)
    top_searches = Analytics.top_searches(days: days, limit: 8)
    no_result_searches = Analytics.searches_without_results(days: days, limit: 8)

    assign(socket,
      days: days,
      summary: Analytics.summary(days: days),
      views_by_day: views_by_day,
      views_max: max_count(views_by_day),
      top_paths: top_paths,
      paths_max: max_count(top_paths),
      top_products: top_products,
      products_max: max_count(top_products),
      top_searches: top_searches,
      searches_max: max_count(top_searches),
      no_result_searches: no_result_searches,
      no_result_max: max_count(no_result_searches)
    )
  end

  defp normalize_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {number, ""} -> normalize_days(number)
      _otherwise -> @default_window
    end
  end

  defp normalize_days(days) when is_integer(days) and days in @windows, do: days
  defp normalize_days(_days), do: @default_window

  defp max_count(rows), do: rows |> Enum.map(&count_of/1) |> Enum.max(fn -> 0 end)

  defp count_of(row) when is_tuple(row), do: elem(row, tuple_size(row) - 1)
  defp count_of(_row), do: 0

  defp pct(_value, base) when base <= 0, do: 0
  defp pct(value, base), do: min(round(value / base * 100), 100)

  # The chart keeps a visible sliver even when a day had a single view, so a
  # non-zero day is never rendered as an invisible bar.
  defp height_pct(_count, max) when max <= 0, do: 4
  defp height_pct(count, max), do: max(pct(count, max), 4)

  defp datetime(%NaiveDateTime{} = dt), do: dt
  defp datetime(%DateTime{} = dt), do: dt
  defp datetime(_other), do: ~N[2000-01-01 00:00:00]

  defp delimit(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp ok(socket), do: {:ok, socket}
end
