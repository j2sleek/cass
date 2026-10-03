defmodule CassWeb.ProductCard do
  @moduledoc """
  Renders a product card for the catalog index, category pages and the
  storefront shelves.

  The card is price-forward, matching how shoppers actually scan a digital
  marketplace: type and name first, then what it costs, then how it is
  delivered. It reads `active_variants` when they are preloaded and degrades to
  "no price" when they are not — it never queries, and it never decides whether
  something is buyable.
  """
  use CassWeb, :html

  alias CassWeb.Format

  attr :product, :any, required: true
  attr :id, :string, default: nil
  attr :class, :string, default: nil

  def product_card(assigns) do
    ~H"""
    <article
      id={@id}
      class={[
        "group relative flex h-full flex-col overflow-hidden rounded-2xl border border-zinc-200 bg-white",
        "shadow-sm transition duration-200 hover:-translate-y-0.5 hover:border-brand-300 hover:shadow-lg",
        "focus-within:border-brand-400 focus-within:ring-2 focus-within:ring-brand-500/30",
        "motion-reduce:transform-none motion-reduce:transition-none",
        "dark:border-white/10 dark:bg-white/5 dark:hover:border-brand-500/40",
        @class
      ]}
    >
      <.link
        navigate={~p"/catalog/products/#{@product.slug}"}
        class="flex h-full flex-col p-5 focus-visible:outline-none"
      >
        <div class="flex items-start justify-between gap-2">
          <span class={[
            "inline-flex shrink-0 items-center rounded-full px-2.5 py-1 text-[0.65rem] font-semibold tracking-wide uppercase",
            type_badge_classes(@product.product_type)
          ]}>
            <span class="sr-only">Product type: </span>{Format.product_type_label(
              @product.product_type
            )}
          </span>

          <span
            :if={@product.featured}
            class="inline-flex shrink-0 items-center gap-1 rounded-full bg-brand-50 px-2 py-1 text-[0.65rem] font-semibold text-brand-700 dark:bg-brand-500/10 dark:text-brand-200"
          >
            <.icon name="hero-star" class="size-3" />Featured
          </span>
        </div>

        <h3 class="mt-4 text-sm leading-5 font-semibold tracking-tight text-zinc-900 dark:text-white">
          {@product.name}
        </h3>

        <p
          :if={@product.short_description}
          class="mt-1.5 line-clamp-2 text-xs leading-5 text-zinc-500 dark:text-zinc-400"
        >
          {@product.short_description}
        </p>

        <p
          :if={Format.delivery_hint(@product.product_type)}
          class="mt-3 flex items-center gap-1.5 text-[0.7rem] font-medium text-zinc-400 dark:text-zinc-500"
        >
          <.icon name="hero-bolt" class="size-3.5 shrink-0" />
          {Format.delivery_hint(@product.product_type)}
        </p>

        <div class="mt-auto flex items-end justify-between gap-3 pt-5">
          <span class="text-lg font-bold tracking-tight text-zinc-900 dark:text-white">
            {Format.product_price(@product)}
          </span>
          <span class="inline-flex items-center gap-1 text-xs font-semibold text-brand-600 transition group-hover:gap-1.5 dark:text-brand-300">
            View <.icon name="hero-arrow-right" class="size-3.5" />
          </span>
        </div>
      </.link>
    </article>
    """
  end

  defp type_badge_classes(:ai),
    do: "bg-accent-50 text-accent-700 dark:bg-accent-500/10 dark:text-accent-300"

  defp type_badge_classes(:smm),
    do: "bg-violet-50 text-violet-700 dark:bg-violet-500/10 dark:text-violet-300"

  defp type_badge_classes(:service),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-500/10 dark:text-amber-300"

  defp type_badge_classes(_digital),
    do: "bg-zinc-100 text-zinc-600 dark:bg-white/10 dark:text-zinc-300"
end
