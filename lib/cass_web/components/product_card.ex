defmodule CassWeb.ProductCard do
  @moduledoc """
  Renders a product card linking to its public page. Used by the catalog
  index and category pages.

  Cards surface the marketplace essentials at a glance: product type, name,
  description, the lowest available price, and the seller identity.
  """
  use CassWeb, :html

  alias Cass.Catalog.ProductType

  attr :product, :map, required: true

  def product_card(assigns) do
    ~H"""
    <div class="group flex h-full flex-col rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-brand-300 hover:shadow-md dark:border-white/10 dark:bg-white/5 dark:hover:border-brand-500/40">
      <.link
        navigate={~p"/catalog/products/#{@product.slug}"}
        class="flex h-full flex-col items-start"
      >
        <div class="flex flex-wrap items-center gap-1.5">
          <span class="rounded-full bg-accent-50 px-2 py-0.5 text-[0.65rem] font-semibold tracking-wide text-accent-700 uppercase dark:bg-accent-500/10 dark:text-accent-300">
            {ProductType.label(@product.product_type)}
          </span>
          <span class="rounded-full bg-zinc-100 px-2 py-0.5 text-[0.65rem] font-medium text-zinc-600 dark:bg-white/10 dark:text-zinc-300">
            {ProductType.delivery_hint(@product.product_type)}
          </span>
        </div>
        <h3 class="mt-4 text-sm font-semibold tracking-tight text-zinc-900 group-hover:text-brand-700 dark:text-white dark:group-hover:text-brand-300">
          {@product.name}
        </h3>
        <%= if @product.short_description do %>
          <p class="mt-1 line-clamp-2 text-xs leading-5 text-zinc-500 dark:text-zinc-400">
            {@product.short_description}
          </p>
        <% end %>
        <div class="mt-4 flex w-full items-end justify-between gap-3">
          <div class="min-w-0">
            <%= if @product.active_variants != [] do %>
              <span class="block text-base font-bold tracking-tight text-zinc-900 dark:text-white">
                {price_label(@product.active_variants)}
              </span>
            <% end %>
            <span class="mt-0.5 block truncate text-xs font-medium text-zinc-500 dark:text-zinc-400">
              {vendor_label(@product)}
            </span>
          </div>
          <span class="grid size-8 shrink-0 place-items-center rounded-full bg-brand-50 text-brand-600 transition group-hover:translate-x-0.5 group-hover:bg-brand-100 dark:bg-brand-500/10 dark:text-brand-300 dark:group-hover:bg-brand-500/20">
            <.icon name="hero-arrow-right" class="size-4" />
          </span>
        </div>
      </.link>
    </div>
    """
  end

  # The lowest price across the active variants, prefixed with "From" when the
  # product offers more than one distinct price point.
  defp price_label(variants) do
    prices = Enum.map(variants, &{&1.price_cents, &1.currency}) |> Enum.uniq()
    {cents, currency} = Enum.min_by(prices, &elem(&1, 0))
    price = money(cents, currency)

    if length(prices) > 1, do: "From #{price}", else: price
  end

  # Seller identity: a platform-owned product is sold by CASS itself; an owned
  # product shows the seller's approved vendor display name when they have one,
  # and otherwise a handle derived from the seller's verified email.
  defp vendor_label(%{owner: nil}), do: "Sold by CASS"

  defp vendor_label(%{owner: %Cass.Accounts.User{} = owner}) do
    case Cass.Vendors.public_name(owner) do
      name when is_binary(name) -> "Sold by #{name}"
      _other -> email_handle_label(owner.email)
    end
  end

  defp vendor_label(_product), do: "Sold by CASS"

  defp email_handle_label(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [handle | _] when handle != "" -> "Sold by #{handle}"
      _ -> "Sold by CASS"
    end
  end

  defp email_handle_label(_email), do: "Sold by CASS"

  defp money(cents, currency) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{currency} #{dollars}.#{remainder}"
  end
end
