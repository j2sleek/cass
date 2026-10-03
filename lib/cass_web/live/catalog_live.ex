defmodule CassWeb.CatalogLive do
  @moduledoc """
  The public catalog index (`/catalog`).

  A marketplace browse surface: a category rail, full-text search across
  publicly discoverable products, a product-type filter, sortable results and
  pagination.

  Every arrangement of results is expressed in the URL (`?query=`, `?type=`,
  `?sort=`, `?category=`, `?page=`) so a shopper can share or bookmark exactly
  what they are looking at, and so the page works with JavaScript disabled.

  All filtering and ordering is delegated to
  `Cass.Catalog.search_public_products/1`, which can only ever narrow the set
  of publicly discoverable products. This module never re-implements a
  visibility rule.
  """
  use CassWeb, :live_view

  alias Cass.Catalog.SearchParams
  alias CassWeb.{ProductCard, Storefront}

  @default_description "Browse digital products, compliant social marketing services, and AI tools in the CASS marketplace catalog."

  @impl true
  def mount(_params, _session, socket) do
    categories = Cass.Catalog.list_public_categories()

    socket
    |> stream(:categories, categories)
    |> assign(:categories_list, categories)
    |> assign(:active_category, nil)
    |> load_results()
    |> assign(:page_title, "Catalog · CASS Marketplace")
    |> assign(:meta_description, @default_description)
    # Filtered and sorted arrangements are all the same inventory, so they
    # canonicalise to /catalog rather than competing as separate pages.
    |> assign(:canonical_url, CassWeb.Endpoint.url() <> ~p"/catalog")
    |> ok()
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:active_category, params["category"])
     |> load_results(params)}
  end

  @impl true
  def handle_event("sort", %{"catalog-sort" => sort}, socket) do
    query = Storefront.catalog_query(socket.assigns.params, sort: sort, page: nil)
    {:noreply, push_patch(socket, to: ~p"/catalog?#{query}")}
  end

  defp load_results(socket, params \\ %{}) do
    search_params = search_params_from(params)

    result = Cass.Catalog.search_public_products(search_params)

    socket
    |> assign(:params, search_params)
    |> assign(:total, result.total)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> stream(:products, result.products, reset: true)
    |> assign(:robots, if(SearchParams.active?(search_params), do: "noindex, follow"))
  end

  # The public URL uses short keys (`type`, `category`); this is the single
  # place they are mapped onto the struct.
  defp search_params_from(params) do
    SearchParams.from_params(%{
      "query" => params["query"],
      "product_type" => params["type"],
      "category_slug" => params["category"],
      "sort" => params["sort"],
      "page" => params["page"],
      "per_page" => params["per_page"]
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section class="border-b border-zinc-200/70 pb-8 dark:border-white/10">
        <h1 class="text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
          Catalog
        </h1>
        <p class="mt-3 max-w-2xl text-base leading-7 text-zinc-600 dark:text-zinc-300">
          Browse digital products, compliant social marketing services, and AI-powered tools,
          all organized into our catalog categories.
        </p>

        <Storefront.search_form
          id="catalog-search"
          value={@params.query}
          class="mt-6 max-w-xl"
        />
      </section>

      <section id="categories" class="scroll-mt-24 pt-8">
        <Storefront.category_rail
          categories={@categories_list}
          active_slug={@active_category}
        />
        <Storefront.section_heading
          id="categories-heading"
          title="Browse categories"
          subtitle={@total > 0 && "#{@total} products available"}
        />

        <div
          id="categories-grid"
          phx-update="stream"
          class="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
        >
          <Storefront.empty_state
            id="empty-categories-grid"
            icon="hero-squares-2x2"
            title="No categories published yet."
            body="Categories appear here as soon as the catalog team publishes them."
          />
          <div
            :for={{id, category} <- @streams.categories}
            id={id}
            class="flex flex-col rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-brand-300 hover:shadow-md motion-reduce:transform-none motion-reduce:transition-none dark:border-white/10 dark:bg-white/5 dark:hover:border-brand-500/40"
          >
            <.link
              navigate={~p"/catalog/categories/#{category.slug}"}
              class="flex h-full flex-col items-start focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:outline-none"
            >
              <span class="grid size-10 place-items-center rounded-xl bg-brand-50 text-brand-600 dark:bg-brand-500/10 dark:text-brand-300">
                <.icon name={Storefront.category_icon(category.id)} class="size-5" />
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
                  <span class="rounded-full bg-zinc-100 px-2 py-0.5 text-[0.65rem] font-medium text-zinc-500 dark:bg-white/10 dark:text-zinc-300">
                    {child.name}
                  </span>
                <% end %>
              </span>
            </.link>
          </div>
        </div>
      </section>

      <section id="products" class="scroll-mt-24 pt-12">
        <h2
          id="products-heading"
          class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white"
        >
          {results_heading(@params)}
        </h2>

        <Storefront.results_bar
          id="catalog-results-bar"
          total={@total}
          params={@params}
          class="mt-4"
        />

        <div
          id="products-grid"
          phx-update="stream"
          class="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
        >
          <Storefront.empty_state
            id="empty-products-grid"
            icon="hero-magnifying-glass"
            title={empty_heading(@params)}
            body={empty_body(@params)}
          />
          <div :for={{id, product} <- @streams.products} id={id}>
            <ProductCard.product_card product={product} />
          </div>
        </div>

        <Storefront.pagination page={@page} total_pages={@total_pages} params={@params} />
      </section>
    </Layouts.app>
    """
  end

  defp results_heading(%SearchParams{query: nil, product_type: nil}), do: "Latest additions"

  defp results_heading(%SearchParams{} = params) do
    if params.query do
      "Results for “#{params.query}”"
    else
      "Filtered products"
    end
  end

  defp empty_heading(%SearchParams{query: nil}), do: "No products published yet."
  defp empty_heading(%SearchParams{}), do: "No products match your search."

  defp empty_body(%SearchParams{query: nil}),
    do: "Products appear here as soon as a seller publishes them to the catalog."

  defp empty_body(%SearchParams{query: query}) when is_binary(query),
    do: "Nothing matched “#{query}”. Try a shorter term, or clear the filters."

  defp empty_body(%SearchParams{}), do: "No product of this type is available right now."

  defp category_has_description(%{description: description})
       when is_binary(description) and description != "",
       do: true

  defp category_has_description(_category), do: false

  defp ok(socket), do: {:ok, socket}
end
