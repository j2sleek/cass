defmodule CassWeb.CategoryLive do
  @moduledoc """
  The public category page (`/catalog/categories/:slug`).

  Serves active categories with their public products and child categories.
  Unknown or archived categories render the shared not-found state.
  """
  use CassWeb, :live_view

  alias CassWeb.{Metadata, NotFound, ProductCard}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Cass.Catalog.get_public_category_by_slug(slug) do
      nil ->
        socket
        |> assign(:not_found, true)
        |> assign(:category, nil)
        |> assign(:products, [])
        |> assign(:parent_chain, [])
        |> assign(:page_title, "Category not found · CASS Marketplace")
        |> assign(:meta_description, "The requested catalog category is not available.")
        |> assign(:robots, "noindex, follow")
        |> ok()

      category ->
        socket
        |> assign(:not_found, false)
        |> assign(:category, category)
        |> stream(:products, Cass.Catalog.list_public_products_by_category(category))
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
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={~p"/catalog"}>
      <%= if @not_found do %>
        <NotFound.not_found resource="category" />
      <% else %>
        <.breadcrumb chain={@parent_chain} current={@category.name} />

        <div class="mt-6 flex items-start justify-between gap-4">
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

        <%= if @category.children != [] do %>
          <div class="mt-6 flex flex-wrap gap-2">
            <%= for child <- @category.children do %>
              <.link
                navigate={~p"/catalog/categories/#{child.slug}"}
                class="inline-flex items-center gap-1.5 rounded-full border border-zinc-200 bg-white px-3 py-1.5 text-xs font-medium text-zinc-600 transition hover:border-brand-300 hover:text-brand-700 dark:border-white/10 dark:bg-white/5 dark:text-zinc-300 dark:hover:text-brand-300"
              >
                {child.name}
              </.link>
            <% end %>
          </div>
        <% end %>

        <section id="products" class="scroll-mt-24 pt-12">
          <h2 class="text-lg font-semibold tracking-tight text-zinc-900 dark:text-white">
            Products in {@category.name}
          </h2>

          <div
            id="category-products"
            phx-update="stream"
            class="mt-5 grid gap-4 sm:grid-cols-2 lg:grid-cols-3"
          >
            <div
              id="empty-category-products"
              class="col-span-full hidden rounded-2xl border border-dashed border-zinc-200 p-8 text-center text-sm text-zinc-500 only:block dark:text-zinc-400 dark:border-white/10"
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
      class="flex items-center gap-1.5 text-xs font-medium text-zinc-500 dark:text-zinc-400"
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

  defp parent_chain(category) do
    category
    |> collect_parents()
    |> Enum.reverse()
  end

  defp collect_parents(%{parent: nil}), do: []
  defp collect_parents(%{parent: parent}), do: [parent | collect_parents(parent)]

  defp ok(socket), do: {:ok, socket}
end
