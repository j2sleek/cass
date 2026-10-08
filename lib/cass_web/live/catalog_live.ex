defmodule CassWeb.CatalogLive do
  @moduledoc """
  The public catalog index (`/catalog`).

  Server-rendered LiveView that surfaces the active root categories and the
  publicly discoverable products, with the storefront's discovery controls:

    * `?q=` — free-text search across the name and descriptions
    * `?sort=` — `newest` (default), `price_asc`, `price_desc`, `name`
    * `?types=` — product-type facets, comma separated (`digital,physical`)
    * `?stock=in` — only products that can be bought right now
    * `?min_price=` / `?max_price=` — a price band in dollars, kept verbatim in
      the URL so a shared link shows exactly what its author typed

  Every control is URL state, so a filtered view is shareable, survives a
  reload, and works with the back button — and each change is one `push_patch`,
  so filtering never remounts the page. Facet counts come from the same in-memory
  list the grid renders (see `Cass.Catalog.product_type_counts/1`), so a count
  and the rows behind it can never disagree. SEO metadata is assigned in
  `mount/3` and rendered by the root layout.
  """
  use CassWeb, :live_view

  alias Cass.Catalog
  alias Cass.Catalog.ProductType
  alias CassWeb.ProductCard

  @default_description "Browse digital products, compliant social marketing services, and AI tools in the CASS marketplace catalog."

  @category_icons [
    "hero-squares-2x2",
    "hero-book-open",
    "hero-tag",
    "hero-cube",
    "hero-sparkles",
    "hero-rocket-launch"
  ]

  @impl true
  def mount(params, _session, socket) do
    socket
    |> stream(:categories, Catalog.list_public_categories())
    |> stream(:products, [])
    |> assign(:page_title, "Catalog · CASS Marketplace")
    |> assign(:meta_description, @default_description)
    |> assign(:canonical_url, CassWeb.Endpoint.url() <> ~p"/catalog")
    |> load_products(params)
    |> ok()
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = load_products(socket, params)

    # A search that produced a catalog view is demand we can measure. The
    # `connected?/1` guard skips the dead render so each interaction is counted
    # once, and each guard skips browsing that asked for nothing.
    if connected?(socket) do
      if socket.assigns.q != "" do
        CassWeb.LiveAnalytics.track(socket, "search",
          path: ~p"/catalog",
          metadata: %{
            "query" => socket.assigns.q,
            "result_count" => socket.assigns.product_count,
            "sort" => socket.assigns.sort
          }
        )
      end

      if socket.assigns.filters_active? do
        CassWeb.LiveAnalytics.track(socket, "filter",
          path: ~p"/catalog",
          metadata: %{
            "types" => Enum.join(socket.assigns.types, ","),
            "in_stock" => to_string(socket.assigns.in_stock),
            "min_price_cents" => socket.assigns.min_price_cents,
            "max_price_cents" => socket.assigns.max_price_cents,
            "result_count" => socket.assigns.product_count,
            "sort" => socket.assigns.sort
          }
        )
      end
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    q = String.trim(q || "")

    {:noreply, push_patch(socket, to: catalog_path(%{socket.assigns | q: q}))}
  end

  def handle_event("sort", %{"sort" => sort}, socket) do
    sort = normalize_sort(sort || "newest")

    {:noreply, push_patch(socket, to: catalog_path(%{socket.assigns | sort: sort}))}
  end

  def handle_event("toggle_type", %{"type" => type}, socket) do
    case resolve_type(type) do
      nil ->
        # Not a member of the closed vocabulary: a tampered payload must simply
        # do nothing rather than filter on something the catalog cannot hold.
        {:noreply, socket}

      type ->
        types =
          if type in socket.assigns.types do
            Enum.reject(socket.assigns.types, &(&1 == type))
          else
            [type | socket.assigns.types]
          end

        # Store the selection in vocabulary order so the same set always
        # produces the same URL, no matter which order it was picked in.
        types = Enum.filter(Catalog.product_types(), &(&1 in types))

        {:noreply, push_patch(socket, to: catalog_path(%{socket.assigns | types: types}))}
    end
  end

  def handle_event("clear_types", _params, socket) do
    {:noreply, push_patch(socket, to: catalog_path(%{socket.assigns | types: []}))}
  end

  def handle_event("toggle_stock", _params, socket) do
    {:noreply,
     push_patch(socket, to: catalog_path(%{socket.assigns | in_stock: !socket.assigns.in_stock}))}
  end

  def handle_event("filter", params, socket) do
    assigns = %{
      socket.assigns
      | min_price_raw: String.trim(params["min_price"] || ""),
        max_price_raw: String.trim(params["max_price"] || "")
    }

    {:noreply, push_patch(socket, to: catalog_path(assigns))}
  end

  def handle_event("clear_filters", _params, socket) do
    assigns = %{
      socket.assigns
      | types: [],
        in_stock: false,
        min_price_raw: "",
        max_price_raw: ""
    }

    {:noreply, push_patch(socket, to: catalog_path(assigns))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/catalog"}>
      <section class="border-b border-zinc-200/70 pb-10 dark:border-white/10">
        <h1 class="text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
          Catalog
        </h1>
        <p class="mt-3 max-w-2xl text-base leading-7 text-zinc-600 dark:text-zinc-300">
          Browse digital products, compliant social marketing services, and AI-powered tools,
          all organized into our catalog categories.
        </p>

        <div class="mt-6 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
          <.form
            for={@search_form}
            id="catalog-search-form"
            phx-submit="search"
            role="search"
            class="flex w-full gap-2 md:max-w-md"
          >
            <.input
              field={@search_form[:q]}
              type="search"
              placeholder="Search products, services, AI tools…"
              aria-label="Search the catalog"
            />
            <button
              id="catalog-search-submit"
              type="submit"
              class="shrink-0 rounded-lg bg-brand-600 px-4 py-2 text-sm font-semibold text-white shadow-sm transition-colors hover:bg-brand-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
            >
              Search
            </button>
          </.form>

          <div class="shrink-0">
            <.form for={@sort_form} id="catalog-sort-form" phx-change="sort">
              <.input
                field={@sort_form[:sort]}
                type="select"
                label="Sort by"
                options={[
                  Newest: "newest",
                  "Price: low to high": "price_asc",
                  "Price: high to low": "price_desc",
                  "Name A–Z": "name"
                ]}
              />
            </.form>
          </div>
        </div>

        <%= if @search_active? do %>
          <p
            id="search-summary"
            class="mt-4 flex flex-wrap items-center gap-x-3 gap-y-2 text-sm text-zinc-600 dark:text-zinc-300"
          >
            <span>
              <strong class="font-semibold text-zinc-900 dark:text-white">{@product_count}</strong>
              {product_word(@product_count)} for “{@q}”
            </span>
            <.link
              patch={~p"/catalog"}
              id="clear-search"
              class="inline-flex items-center gap-1 rounded-lg border border-zinc-200 bg-white px-2.5 py-1 text-xs font-medium text-zinc-600 transition hover:border-brand-300 hover:text-brand-700 dark:border-white/10 dark:bg-white/5 dark:text-zinc-300 dark:hover:text-brand-300"
            >
              Clear search <.icon name="hero-x-mark" class="size-3" />
            </.link>
          </p>
        <% end %>
      </section>

      <section
        id="type-filters"
        class="scroll-mt-24 pt-8"
        aria-label="Filter the catalog"
      >
        <div class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div
            class="min-w-0"
            role="group"
            aria-label="Filter by product type"
          >
            <div class="flex flex-wrap items-center gap-2">
              <span
                id="type-filters-label"
                class="mr-1 text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400"
              >
                Type
              </span>

              <button
                type="button"
                id="type-all"
                phx-click="clear_types"
                aria-pressed={if(@types == [], do: "true", else: "false")}
                class={type_chip_class(@types == [])}
              >
                All
              </button>

              <button
                :for={{type, count} <- @type_facets}
                type="button"
                id={"type-#{type}"}
                phx-click="toggle_type"
                phx-value-type={type}
                aria-pressed={if(type in @types, do: "true", else: "false")}
                class={type_chip_class(type in @types)}
              >
                {ProductType.label(type)}
                <span class={[
                  "ml-1 rounded-full px-1.5 py-0.5 text-[0.65rem] font-semibold tabular-nums",
                  if(type in @types,
                    do: "bg-white/25 text-white",
                    else: "bg-zinc-100 text-zinc-500 dark:bg-white/10 dark:text-zinc-400"
                  )
                ]}>
                  {count}
                </span>
              </button>
            </div>
          </div>

          <div class="flex flex-wrap items-end gap-3">
            <button
              type="button"
              id="stock-toggle"
              phx-click="toggle_stock"
              aria-pressed={if(@in_stock, do: "true", else: "false")}
              class={type_chip_class(@in_stock)}
            >
              <.icon name="hero-check-badge" class="size-4" /> In stock only
            </button>

            <.form
              for={@filter_form}
              id="catalog-price-form"
              phx-submit="filter"
              class="flex items-end gap-2"
            >
              <div class="w-32">
                <.input
                  field={@filter_form[:min_price]}
                  type="number"
                  label="Min $"
                  placeholder="0"
                  min="0"
                  step="0.01"
                />
              </div>
              <div class="w-32">
                <.input
                  field={@filter_form[:max_price]}
                  type="number"
                  label="Max $"
                  placeholder="Any"
                  min="0"
                  step="0.01"
                />
              </div>
              <button
                id="catalog-price-submit"
                type="submit"
                class="mb-[2px] h-10 shrink-0 rounded-lg border border-zinc-200 bg-white px-3 text-sm font-medium text-zinc-700 transition hover:border-brand-300 hover:text-brand-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 dark:border-white/10 dark:bg-white/5 dark:text-zinc-200 dark:hover:border-brand-500/40 dark:hover:text-brand-300"
              >
                Apply
              </button>
            </.form>

            <button
              :if={@filters_active?}
              type="button"
              id="clear-filters"
              phx-click="clear_filters"
              class="mb-[2px] h-10 shrink-0 rounded-lg px-3 text-sm font-medium text-zinc-500 underline-offset-4 transition hover:text-brand-700 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 dark:text-zinc-400 dark:hover:text-brand-300"
            >
              Clear filters
            </button>
          </div>
        </div>

        <%= if @filters_active? do %>
          <p
            id="filter-summary"
            class="mt-4 flex flex-wrap items-center gap-x-3 gap-y-2 text-sm text-zinc-600 dark:text-zinc-300"
          >
            <span>
              <strong class="font-semibold text-zinc-900 dark:text-white">{@product_count}</strong>
              {product_word(@product_count)} match your filters
            </span>
            <span class="hidden h-3 w-px bg-zinc-200 dark:bg-white/10 sm:block" aria-hidden="true"></span>
            <span class="flex flex-wrap items-center gap-1.5">
              <span
                :for={type <- @types}
                class="inline-flex items-center gap-1 rounded-full bg-brand-50 px-2.5 py-1 text-xs font-medium text-brand-700 dark:bg-brand-500/10 dark:text-brand-300"
              >
                {ProductType.label(type)}
                <button
                  type="button"
                  id={"remove-type-#{type}"}
                  phx-click="toggle_type"
                  phx-value-type={type}
                  aria-label={"Remove the " <> ProductType.label(type) <> " filter"}
                  class="rounded-full p-0.5 transition hover:bg-brand-100 dark:hover:bg-brand-500/20"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </span>
              <span
                :if={@in_stock}
                class="inline-flex items-center gap-1 rounded-full bg-brand-50 px-2.5 py-1 text-xs font-medium text-brand-700 dark:bg-brand-500/10 dark:text-brand-300"
              >
                In stock only
                <button
                  type="button"
                  id="remove-stock-filter"
                  phx-click="toggle_stock"
                  aria-label="Remove the in-stock filter"
                  class="rounded-full p-0.5 transition hover:bg-brand-100 dark:hover:bg-brand-500/20"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </span>
              <span
                :if={@min_price_cents != nil or @max_price_cents != nil}
                class="inline-flex items-center gap-1 rounded-full bg-brand-50 px-2.5 py-1 text-xs font-medium text-brand-700 dark:bg-brand-500/10 dark:text-brand-300"
              >
                {price_band_label(@min_price_cents, @max_price_cents)}
                <button
                  type="button"
                  id="remove-price-filter"
                  phx-click="clear_filters"
                  aria-label="Remove the price filter"
                  class="rounded-full p-0.5 transition hover:bg-brand-100 dark:hover:bg-brand-500/20"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </span>
            </span>
          </p>
        <% end %>
      </section>

      <section id="categories" class="scroll-mt-24 pt-10">
        <div class="flex items-baseline justify-between">
          <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
            Browse categories
          </h2>
          <span class="text-xs font-medium text-zinc-500 dark:text-zinc-400">
            {@product_count} products available
          </span>
        </div>

        <div
          id="categories-grid"
          phx-update="stream"
          class="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
        >
          <div
            id="empty-categories-grid"
            class="col-span-full hidden rounded-2xl border border-dashed border-zinc-200 p-8 text-center text-sm text-zinc-500 only:block dark:text-zinc-400 dark:border-white/10"
          >
            No categories published yet.
          </div>
          <div
            :for={{id, category} <- @streams.categories}
            id={id}
            class="flex flex-col rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-brand-300 hover:shadow-md dark:border-white/10 dark:bg-white/5 dark:hover:border-brand-500/40"
          >
            <.link
              navigate={~p"/catalog/categories/#{category.slug}"}
              class="flex h-full flex-col items-start"
            >
              <span class="grid size-10 place-items-center rounded-xl bg-brand-50 text-brand-600 dark:bg-brand-500/10 dark:text-brand-300">
                <.icon name={category_icon(category.id)} class="size-5" />
              </span>
              <span class="mt-4 text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
                {category.name}
              </span>
              <%= if category_has_description(category) do %>
                <span class="mt-1 line-clamp-2 text-xs leading-5 text-zinc-500 dark:text-zinc-400">
                  {category.description}
                </span>
              <% end %>
              <span class="mt-3 flex flex-wrap gap-1.5">
                <%= for child <- category.children do %>
                  <span class="rounded-full bg-zinc-100 px-2 py-0.5 text-[0.65rem] font-medium text-zinc-600 dark:bg-white/10 dark:text-zinc-300">
                    {child.name}
                  </span>
                <% end %>
              </span>
            </.link>
          </div>
        </div>
      </section>

      <section id="products" class="scroll-mt-24 pt-12">
        <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
          {products_heading(@search_active?, @filters_active?)}
        </h2>

        <div
          id="products-grid"
          phx-update="stream"
          class="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
        >
          <div
            id="empty-products-grid"
            class="col-span-full hidden rounded-2xl border border-dashed border-zinc-200 p-8 text-center text-sm text-zinc-500 only:block dark:text-zinc-400 dark:border-white/10"
          >
            <%= cond do %>
              <% @search_active? -> %>
                No products match your search for “{@q}”. Try a different term or browse all products.
              <% @filters_active? -> %>
                No products match these filters. Try clearing a filter to widen the results.
              <% true -> %>
                No products published yet.
            <% end %>
          </div>
          <div :for={{id, product} <- @streams.products} id={id}>
            <ProductCard.product_card product={product} />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_products(socket, params) do
    q = String.trim(params["q"] || "")
    sort = normalize_sort(params["sort"] || "newest")
    types = parse_types(params["types"])
    in_stock = params["stock"] == "in"
    min_price_raw = String.trim(params["min_price"] || "")
    max_price_raw = String.trim(params["max_price"] || "")
    min_price_cents = parse_cents(min_price_raw)
    max_price_cents = parse_cents(max_price_raw)

    # Facet counts are taken *before* the type filter and *after* the other
    # filters, which is exactly the question a chip answers: "how many would I
    # see if I picked this type, holding everything else still?"
    base =
      Cass.Catalog.list_public_products(q: q, sort: sort)
      |> Cass.Catalog.filter_by_price_band(min_price_cents, max_price_cents)
      |> Cass.Catalog.filter_by_stock(in_stock)

    type_counts = Cass.Catalog.product_type_counts(base)
    products = Cass.Catalog.filter_by_product_types(base, types)

    filters_active? = types != [] or in_stock or min_price_cents != nil or max_price_cents != nil

    socket
    |> assign(:q, q)
    |> assign(:sort, sort)
    |> assign(:types, types)
    |> assign(:in_stock, in_stock)
    |> assign(:min_price_raw, min_price_raw)
    |> assign(:max_price_raw, max_price_raw)
    |> assign(:min_price_cents, min_price_cents)
    |> assign(:max_price_cents, max_price_cents)
    |> assign(:search_form, to_form(%{"q" => q}))
    |> assign(:sort_form, to_form(%{"sort" => sort}))
    |> assign(
      :filter_form,
      to_form(%{"min_price" => min_price_raw, "max_price" => max_price_raw})
    )
    |> assign(:type_facets, type_facets(type_counts))
    |> assign(:search_active?, q != "")
    |> assign(:filters_active?, filters_active?)
    |> assign(:product_count, length(products))
    |> stream(:products, products, reset: true)
  end

  # Facets are listed in vocabulary order, not map order, so the chips never
  # reshuffle between renders.
  defp type_facets(counts) do
    Enum.map(Catalog.product_types(), fn type -> {type, Map.get(counts, type, 0)} end)
  end

  # Reads the comma-separated `?types=` list against the closed vocabulary, so a
  # tampered URL can only ever select a type the catalog actually has — the atom
  # is looked up in a map built from `product_types/0`, never created from input.
  defp parse_types(nil), do: []

  defp parse_types(raw) when is_list(raw) do
    raw |> Enum.join(",") |> parse_types()
  end

  defp parse_types(raw) when is_binary(raw) do
    allowed = type_lookup()

    wanted =
      raw
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&Map.get(allowed, &1))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(Catalog.product_types(), &MapSet.member?(wanted, &1))
  end

  defp parse_types(_other), do: []

  # Turns a `?types=` member into the vocabulary atom it names, or `nil` when it
  # is not a member at all. The atom comes from `product_types/0`, never from
  # `String.to_atom/1`, so a tampered URL cannot mint new atoms.
  defp resolve_type(type) when is_binary(type) do
    Map.get(type_lookup(), type)
  end

  defp resolve_type(_type), do: nil

  defp type_lookup do
    Map.new(Catalog.product_types(), fn type -> {to_string(type), type} end)
  end

  # A price band is typed in dollars and read from the URL verbatim, so the
  # field round-trips exactly what the buyer wrote ("5.99" stays "5.99"). Only
  # what actually reaches the query has to parse, and anything unparseable (or
  # negative) simply applies no bound instead of failing the page.
  defp parse_cents(""), do: nil

  defp parse_cents(raw) when is_binary(raw) do
    case Float.parse(raw) do
      {amount, ""} when amount >= 0 -> round(amount * 100)
      _unparseable -> nil
    end
  end

  defp parse_cents(_raw), do: nil

  defp price_band_label(nil, nil), do: "Any price"

  defp price_band_label(min_price_cents, nil) do
    "From #{money(min_price_cents)}"
  end

  defp price_band_label(nil, max_price_cents) do
    "Up to #{money(max_price_cents)}"
  end

  defp price_band_label(min_price_cents, max_price_cents) do
    "#{money(min_price_cents)} – #{money(max_price_cents)}"
  end

  defp money(cents) do
    dollars = div(cents, 100)
    remainder = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "$#{dollars}.#{remainder}"
  end

  defp type_chip_class(selected?) do
    base =
      "inline-flex h-9 items-center gap-1 rounded-full border px-3 text-sm font-medium transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"

    skin =
      if selected? do
        "border-brand-600 bg-brand-600 text-white shadow-sm hover:border-brand-700 hover:bg-brand-700 dark:border-brand-500 dark:bg-brand-500 dark:hover:bg-brand-400"
      else
        "border-zinc-200 bg-white text-zinc-700 hover:border-brand-300 hover:text-brand-700 dark:border-white/10 dark:bg-white/5 dark:text-zinc-300 dark:hover:border-brand-500/40 dark:hover:text-brand-300"
      end

    base <> " " <> skin
  end

  defp products_heading(search_active?, filters_active?) do
    cond do
      search_active? -> "Search results"
      filters_active? -> "Filtered results"
      true -> "Latest additions"
    end
  end

  defp normalize_sort(sort) when sort in ["name", "price_asc", "price_desc"], do: sort
  defp normalize_sort("newest"), do: "newest"
  defp normalize_sort(_other), do: "newest"

  # Builds the canonical URL for the current discovery state. Defaults (an empty
  # query, the default sort, no facets) are dropped so `/catalog` stays clean.
  #
  # The query string is composed by hand instead of through the `~p` sigil so a
  # shared link reads the way the author typed it: `types` stays comma separated
  # (`types=digital,physical`), `min_price` precedes `max_price`, and only
  # genuinely unsafe characters are percent-encoded. The router still decodes
  # the values back to exactly what `parse_types/1` and `parse_cents/1` expect.
  defp catalog_path(state) do
    params =
      [
        {"q", param_value(state.q)},
        {"sort", param_value(if(state.sort == "newest", do: nil, else: state.sort))},
        {"types", param_value(if(state.types == [], do: nil, else: Enum.join(state.types, ",")))},
        {"stock", param_value(if(state.in_stock, do: "in", else: nil))},
        {"min_price", param_value(state.min_price_raw)},
        {"max_price", param_value(state.max_price_raw)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case params do
      [] ->
        ~p"/catalog"

      _ ->
        "/catalog?" <>
          Enum.map_join(params, "&", fn {key, value} -> "#{key}=#{uri_value(value)}" end)
    end
  end

  # Values may contain commas (a `types=` list) and dots (a typed price), which
  # are both safe in a query value; everything else is percent-encoded.
  defp uri_value(value) when is_binary(value) do
    URI.encode(value, &(URI.char_unreserved?(&1) or &1 == ?,))
  end

  defp param_value(""), do: nil
  defp param_value(value), do: value

  defp product_word(1), do: "result"
  defp product_word(_count), do: "results"

  defp category_has_description(%{description: description})
       when is_binary(description) and description != "",
       do: true

  defp category_has_description(_category), do: false

  defp category_icon(id), do: Enum.at(@category_icons, rem(id, length(@category_icons)))

  defp ok(socket), do: {:ok, socket}
end
