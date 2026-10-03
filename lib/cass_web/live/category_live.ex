defmodule CassWeb.CategoryLive do
  @moduledoc """
  The public category page (`/catalog/categories/:slug`).

  Serves active categories with their public products and child categories.
  Unknown or archived categories render the shared not-found state.
  """
  use CassWeb, :live_view

  alias CassWeb.{Metadata, NotFound, ProductCard, Storefront}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Cass.Catalog.get_public_category_by_slug(slug) do
      nil ->
        socket
        |> assign(:not_found, true)
        |> assign(:category, nil)
        |> stream(:products, [])
        |> assign(:product_count, 0)
        |> assign(:parent_chain, [])
        |> assign(:page_title, "Category not found · CASS Marketplace")
        |> assign(:meta_description, "The requested catalog category is not available.")
        |> assign(:robots, "noindex, follow")
        |> ok()

      category ->
        products = Cass.Catalog.list_public_products_by_category(category)

        socket
        |> assign(:not_found, false)
        |> assign(:category, category)
        |> stream(:products, products)
        |> assign(:product_count, length(products))
        |> assign(:parent_chain, parent_chain(category))
        |> assign(:page_title, "#{Metadata.title(category)} · CASS Marketplace")
        |> assign(:meta_description, Metadata.category_description(category))
        |> assign(
          :canonical_url,
          CassWeb.Endpoint.url() <> ~p"/catalog/categories/#{category.slug}"
        )
        |> ok()
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%= if @not_found do %>
        <NotFound.not_found resource="category" />
      <% else %>
        <.breadcrumb chain={@parent_chain} current={@category.name} />

        <section
          id="category-header"
          class="relative mt-6 overflow-hidden rounded-3xl border border-zinc-200 bg-gradient-to-br from-brand-50/70 to-white p-7 sm:p-9 dark:border-white/10 dark:from-brand-950/40 dark:to-white/5"
        >
          <div
            class="pointer-events-none absolute -right-16 -top-20 size-64 rounded-full bg-brand-200/50 blur-3xl dark:bg-brand-700/20"
            aria-hidden="true"
          >
          </div>

          <div class="relative flex flex-col gap-6 sm:flex-row sm:items-start sm:justify-between">
            <div class="flex items-start gap-4">
              <span class="grid size-12 shrink-0 place-items-center rounded-2xl bg-white text-brand-700 shadow-sm dark:bg-white/10 dark:text-brand-200">
                <.icon name={Storefront.category_icon(@category.id)} class="size-6" />
              </span>
              <div>
                <h1 class="text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
                  {@category.name}
                </h1>
                <%= if @category.description do %>
                  <p class="mt-3 max-w-2xl text-base leading-7 text-zinc-600 dark:text-zinc-300">
                    {@category.description}
                  </p>
                <% end %>
              </div>
            </div>

            <.link
              navigate={~p"/catalog"}
              class="inline-flex shrink-0 items-center gap-1.5 self-start rounded-full border border-zinc-200 bg-white px-4 py-2 text-sm font-semibold text-zinc-700 transition hover:border-brand-300 hover:text-brand-700 dark:border-white/10 dark:bg-white/5 dark:text-zinc-200 dark:hover:border-brand-500 dark:hover:text-brand-200"
            >
              <.icon name="hero-arrow-left" class="size-4" /> All products
            </.link>
          </div>
        </section>

        <%= if @category.children != [] do %>
          <section id="subcategories" class="mt-10" aria-labelledby="subcategories-heading">
            <h2
              id="subcategories-heading"
              class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white"
            >
              Browse subcategories
            </h2>
            <ul
              id="subcategory-grid"
              class="mt-4 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4"
            >
              <li
                :for={child <- @category.children}
                class="group relative flex flex-col rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm transition duration-200 hover:-translate-y-0.5 hover:border-brand-300 hover:shadow-md motion-reduce:transform-none dark:border-white/10 dark:bg-white/5 dark:hover:border-brand-500/40"
              >
                <.link
                  navigate={~p"/catalog/categories/#{child.slug}"}
                  class="flex h-full flex-col focus-visible:outline-none"
                >
                  <span class="grid size-10 place-items-center rounded-xl bg-brand-50 text-brand-700 transition-colors group-hover:bg-brand-100 dark:bg-brand-950 dark:text-brand-300 dark:group-hover:bg-brand-900">
                    <.icon name={Storefront.category_icon(child.id)} class="size-5" />
                  </span>
                  <span class="mt-3 text-sm font-semibold text-zinc-900 dark:text-white">
                    {child.name}
                  </span>
                  <span
                    :if={child.description}
                    class="mt-1 line-clamp-2 text-xs leading-5 text-zinc-500 dark:text-zinc-400"
                  >
                    {child.description}
                  </span>
                </.link>
              </li>
            </ul>
          </section>
        <% end %>

        <section
          id="products"
          class="scroll-mt-24 pt-12"
          aria-labelledby="category-products-heading"
        >
          <div class="flex flex-wrap items-end justify-between gap-3">
            <h2
              id="category-products-heading"
              class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white"
            >
              Products in {@category.name}
            </h2>
            <p id="category-product-count" class="text-sm text-zinc-500 dark:text-zinc-400">
              {pluralize(@product_count, "product", "products")}
            </p>
          </div>

          <div
            id="category-products"
            phx-update="stream"
            class="mt-5 grid gap-5 sm:grid-cols-2 lg:grid-cols-4"
          >
            <div
              id="empty-category-products"
              class="col-span-full hidden rounded-2xl border border-dashed border-zinc-200 p-8 text-center text-sm text-zinc-400 only:block dark:border-white/10"
            >
              No products in this category yet.
            </div>
            <div :for={{id, product} <- @streams.products} id={id}>
              <ProductCard.product_card product={product} />
            </div>
          </div>
        </section>
      <% end %>
    </Layouts.app>
    """
  end

  attr :chain, :list, required: true
  attr :current, :string, required: true

  defp breadcrumb(assigns) do
    ~H"""
    <nav
      aria-label="Breadcrumb"
      class="flex items-center gap-1.5 text-xs font-medium text-zinc-400 dark:text-zinc-500"
    >
      <.link navigate={~p"/"} class="transition hover:text-brand-700 dark:hover:text-brand-300">
        Home
      </.link>
      <.icon name="hero-chevron-right" class="size-3" />
      <.link navigate={~p"/catalog"} class="transition hover:text-brand-700 dark:hover:text-brand-300">
        Catalog
      </.link>
      <%= for parent <- @chain do %>
        <.icon name="hero-chevron-right" class="size-3" />
        <.link
          navigate={~p"/catalog/categories/#{parent.slug}"}
          class="transition hover:text-brand-700 dark:hover:text-brand-300"
        >
          {parent.name}
        </.link>
      <% end %>
      <.icon name="hero-chevron-right" class="size-3" />
      <span class="text-zinc-600 dark:text-zinc-300">{@current}</span>
    </nav>
    """
  end

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(count, _singular, plural), do: "#{count} #{plural}"

  defp parent_chain(category) do
    category
    |> collect_parents()
    |> Enum.reverse()
  end

  defp collect_parents(%{parent: nil}), do: []
  defp collect_parents(%{parent: parent}), do: [parent | collect_parents(parent)]

  defp ok(socket), do: {:ok, socket}
end
