defmodule CassWeb.ProductCard do
  @moduledoc """
  Renders a product card linking to its public page. Used by the catalog
  index and category pages.
  """
  use CassWeb, :html

  @product_type_labels %{
    digital: "Digital",
    smm: "SMM",
    ai: "AI",
    service: "Service"
  }

  attr :product, :map, required: true

  def product_card(assigns) do
    ~H"""
    <div class="flex flex-col rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-brand-300 hover:shadow-md dark:border-white/10 dark:bg-white/5 dark:hover:border-brand-500/40">
      <.link
        navigate={~p"/catalog/products/#{@product.slug}"}
        class="flex h-full flex-col items-start"
      >
        <span class="rounded-full bg-accent-50 px-2 py-0.5 text-[0.65rem] font-semibold tracking-wide text-accent-700 uppercase dark:bg-accent-500/10 dark:text-accent-300">
          {product_type_label(@product.product_type)}
        </span>
        <h3 class="mt-4 text-sm font-semibold tracking-tight text-zinc-900 group-hover:text-brand-700 dark:text-white dark:group-hover:text-brand-300">
          {@product.name}
        </h3>
        <%= if @product.short_description do %>
          <p class="mt-1 line-clamp-2 text-xs leading-5 text-zinc-500 dark:text-zinc-400">
            {@product.short_description}
          </p>
        <% end %>
        <span class="mt-4 inline-flex items-center gap-1 text-xs font-semibold text-brand-600 dark:text-brand-300">
          View product
          <.icon
            name="hero-arrow-right"
            class="size-3.5 transition group-hover:translate-x-0.5"
          />
        </span>
      </.link>
    </div>
    """
  end

  defp product_type_label(product_type), do: Map.fetch!(@product_type_labels, product_type)
end
