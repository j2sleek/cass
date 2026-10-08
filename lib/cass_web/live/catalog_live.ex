defmodule CassWeb.CatalogLive do
  @moduledoc """
  The public catalog index (`/catalog`).

  Server-rendered LiveView that surfaces the active root categories and the
  publicly discoverable products, with lightweight marketplace discovery
  controls: free-text search (`?q=`) and sorting (`?sort=`). SEO metadata is
  assigned in `mount/3` and rendered by the root layout.
  """
  use CassWeb, :live_view

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
    |> stream(:categories, Cass.Catalog.list_public_categories())
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
    # `connected?/1` guard skips the dead render so each search is counted once,
    # and the `q != ""` guard skips browsing without a query.
    if connected?(socket) and socket.assigns.q != "" do
      CassWeb.LiveAnalytics.track(socket, "search",
        path: ~p"/catalog",
        metadata: %{
          "query" => socket.assigns.q,
          "result_count" => socket.assigns.product_count,
          "sort" => socket.assigns.sort
        }
      )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    q = String.trim(q || "")

    {:noreply, push_patch(socket, to: catalog_path(q, socket.assigns.sort))}
  end

  @impl true
  def handle_event("sort", %{"sort" => sort}, socket) do
    sort = normalize_sort(sort || "newest")

    {:noreply, push_patch(socket, to: catalog_path(socket.assigns.q, sort))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
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
          {if @search_active?, do: "Search results", else: "Latest additions"}
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
            <%= if @search_active? do %>
              No products match your search for “{@q}”. Try a different term or browse all products.
            <% else %>
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
    products = Cass.Catalog.list_public_products(q: q, sort: sort)

    socket
    |> assign(:q, q)
    |> assign(:sort, sort)
    |> assign(:search_form, to_form(%{"q" => q}))
    |> assign(:sort_form, to_form(%{"sort" => sort}))
    |> assign(:search_active?, q != "")
    |> assign(:product_count, length(products))
    |> stream(:products, products, reset: true)
  end

  defp normalize_sort(sort) when sort in ["name", "price_asc", "price_desc"], do: sort
  defp normalize_sort("newest"), do: "newest"
  defp normalize_sort(_other), do: "newest"

  defp catalog_path(q, sort) do
    params =
      for {key, value} <- [q: q, sort: sort], value not in ["", nil, "newest"], do: {key, value}

    if params == [], do: ~p"/catalog", else: ~p"/catalog?#{params}"
  end

  defp product_word(1), do: "result"
  defp product_word(_count), do: "results"

  defp category_has_description(%{description: description})
       when is_binary(description) and description != "",
       do: true

  defp category_has_description(_category), do: false

  defp category_icon(id), do: Enum.at(@category_icons, rem(id, length(@category_icons)))

  defp ok(socket), do: {:ok, socket}
end
