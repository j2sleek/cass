defmodule CassWeb.ProductLive do
  @moduledoc """
  The public product page (`/catalog/products/:slug`).

  Serves published products with `:public` or `:unlisted` visibility. Unlisted
  products are marked `noindex`. Drafts, archived items, `:private` products,
  products in non-active categories, and unknown slugs render the shared
  not-found state.
  """
  use CassWeb, :live_view

  alias CassWeb.{Metadata, NotFound}

  @product_type_labels %{
    digital_product: "Digital product",
    smm_service: "Social service",
    ai_tool: "AI tool"
  }

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Cass.Catalog.get_public_product_by_slug(slug) do
      nil ->
        socket
        |> assign(:not_found, true)
        |> assign(:product, nil)
        |> assign(:page_title, "Product not found · CASS Marketplace")
        |> assign(:meta_description, "The requested product is not available.")
        |> assign(:robots, "noindex, follow")
        |> ok()

      product ->
        socket
        |> assign(:not_found, false)
        |> assign(:product, product)
        |> assign(:page_title, "#{Metadata.title(product)} · CASS Marketplace")
        |> assign(:meta_description, Metadata.product_description(product))
        |> assign(:canonical_url, CassWeb.Endpoint.url() <> ~p"/catalog/products/#{product.slug}")
        |> assign(:robots, robots(product.visibility))
        |> ok()
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%= if @not_found do %>
        <NotFound.not_found resource="product" />
      <% else %>
        <nav
          aria-label="Breadcrumb"
          class="flex items-center gap-1.5 text-xs font-medium text-zinc-400 dark:text-zinc-500"
        >
          <.link navigate={~p"/"} class="transition hover:text-brand-700 dark:hover:text-brand-300">
            Home
          </.link>
          <.icon name="hero-chevron-right" class="size-3" />
          <.link
            navigate={~p"/catalog"}
            class="transition hover:text-brand-700 dark:hover:text-brand-300"
          >
            Catalog
          </.link>
          <.icon name="hero-chevron-right" class="size-3" />
          <.link
            navigate={~p"/catalog/categories/#{@product.category.slug}"}
            class="transition hover:text-brand-700 dark:hover:text-brand-300"
          >
            {@product.category.name}
          </.link>
          <.icon name="hero-chevron-right" class="size-3" />
          <span class="text-zinc-600 dark:text-zinc-300">{@product.name}</span>
        </nav>

        <div class="mt-6 grid gap-10 lg:grid-cols-3">
          <div class="lg:col-span-2">
            <div class="flex flex-wrap items-center gap-2">
              <span class="rounded-full bg-accent-50 px-2.5 py-1 text-xs font-semibold tracking-wide text-accent-700 uppercase dark:bg-accent-500/10 dark:text-accent-300">
                {product_type_label(@product.product_type)}
              </span>
              <%= if @product.visibility == :unlisted do %>
                <span class="rounded-full bg-zinc-100 px-2.5 py-1 text-xs font-medium text-zinc-500 dark:bg-white/10 dark:text-zinc-300">
                  Unlisted
                </span>
              <% end %>
            </div>

            <h1 class="mt-4 text-3xl font-bold tracking-tight text-zinc-900 sm:text-4xl dark:text-white">
              {@product.name}
            </h1>

            <%= if @product.short_description do %>
              <p class="mt-3 text-base leading-7 text-zinc-600 dark:text-zinc-300">
                {@product.short_description}
              </p>
            <% end %>

            <%= if @product.description do %>
              <div class="mt-8 whitespace-pre-line text-sm leading-7 text-zinc-600 dark:text-zinc-300">
                {@product.description}
              </div>
            <% end %>
          </div>

          <aside id="product-details" class="lg:col-span-1">
            <div class="rounded-2xl border border-zinc-200 bg-white p-6 shadow-sm dark:border-white/10 dark:bg-white/5">
              <h2 class="text-sm font-semibold tracking-tight text-zinc-900 dark:text-white">
                Product details
              </h2>
              <dl class="mt-4 space-y-4 text-sm">
                <div class="flex items-center justify-between gap-4">
                  <dt class="text-zinc-500 dark:text-zinc-400">Category</dt>
                  <dd>
                    <.link
                      navigate={~p"/catalog/categories/#{@product.category.slug}"}
                      class="font-medium text-brand-600 hover:text-brand-700 dark:text-brand-300"
                    >
                      {@product.category.name}
                    </.link>
                  </dd>
                </div>
                <div class="flex items-center justify-between gap-4">
                  <dt class="text-zinc-500 dark:text-zinc-400">Published</dt>
                  <dd class="text-zinc-700 dark:text-zinc-200">
                    {format_date(@product.published_at)}
                  </dd>
                </div>
              </dl>

              <div class="mt-6 rounded-xl bg-zinc-50 p-4 text-xs leading-5 text-zinc-500 dark:bg-white/5 dark:text-zinc-400">
                Purchase and delivery options for this product are coming soon as the
                marketplace grows.
              </div>
            </div>
          </aside>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  defp product_type_label(product_type), do: Map.fetch!(@product_type_labels, product_type)

  defp robots(:unlisted), do: "noindex, follow"
  defp robots(_visibility), do: nil

  defp format_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%B %d, %Y")
  defp format_date(_), do: "TBA"

  defp ok(socket), do: {:ok, socket}
end
