defmodule CassWeb.CatalogLive do
  @moduledoc """
  The public catalog index (`/catalog`).

  Server-rendered LiveView that surfaces the active root categories and the
  latest publicly discoverable products. SEO metadata is assigned in `mount/3`
  and rendered by the root layout.
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
  def mount(_params, _session, socket) do
    categories = Cass.Catalog.list_public_categories()
    products = Cass.Catalog.list_public_products()

    socket
    |> stream(:categories, categories)
    |> stream(:products, products)
    |> assign(:product_count, length(products))
    |> assign(:page_title, "Catalog · CASS Marketplace")
    |> assign(:meta_description, @default_description)
    |> assign(:canonical_url, CassWeb.Endpoint.url() <> ~p"/catalog")
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="border-b border-zinc-200/70 pb-10 dark:border-white/10">
        <h1 class="text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
          Catalog
        </h1>
        <p class="mt-3 max-w-2xl text-base leading-7 text-zinc-600 dark:text-zinc-300">
          Browse digital products, compliant social marketing services, and AI-powered tools,
          all organized into our catalog categories.
        </p>
      </section>

      <section id="categories" class="scroll-mt-24 pt-10">
        <div class="flex items-baseline justify-between">
          <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
            Browse categories
          </h2>
          <span class="text-xs font-medium text-zinc-400">
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
            class="col-span-full hidden rounded-2xl border border-dashed border-zinc-200 p-8 text-center text-sm text-zinc-400 only:block dark:border-white/10"
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
        <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
          Latest additions
        </h2>

        <div
          id="products-grid"
          phx-update="stream"
          class="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
        >
          <div
            id="empty-products-grid"
            class="col-span-full hidden rounded-2xl border border-dashed border-zinc-200 p-8 text-center text-sm text-zinc-400 only:block dark:border-white/10"
          >
            No products published yet.
          </div>
          <div :for={{id, product} <- @streams.products} id={id}>
            <ProductCard.product_card product={product} />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp category_has_description(%{description: description})
       when is_binary(description) and description != "",
       do: true

  defp category_has_description(_category), do: false

  defp category_icon(id), do: Enum.at(@category_icons, rem(id, length(@category_icons)))

  defp ok(socket), do: {:ok, socket}
end
