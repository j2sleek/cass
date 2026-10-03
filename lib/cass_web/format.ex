defmodule CassWeb.Format do
  @moduledoc """
  Presentation-only helpers for values that appear in more than one storefront
  template (money, dates, product type labels).

  These are deliberately pure string builders with no database access and no
  authorization decisions. Anything that decides *whether* something is
  purchasable belongs in a context (`Cass.Delivery`, `Cass.Catalog`), never
  here.
  """

  alias Cass.Catalog.Product

  @doc """
  Formats integer minor units as an exact decimal amount, e.g. `12345` →
  `"USD 123.45"`.

  Integer division is used rather than float maths so a large price can never
  render `123.45000000000002`. A `nil` price is reported as unavailable rather
  than as `0`, because a free product and an unpriced one are different things.
  """
  def money(cents, currency \\ "USD")

  def money(nil, currency), do: "Not available in #{currency}"

  def money(cents, currency) when is_integer(cents) and cents >= 0 do
    units = div(cents, 100)
    minor = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{currency} #{units}.#{minor}"
  end

  def money(cents, currency) when is_integer(cents), do: "#{currency} #{cents}"

  @doc """
  Formats the price of the cheapest active variant of a product, delegating to
  `Cass.Catalog.cheapest_active_variant/1` for the variant choice.
  """
  def product_price(product, currency \\ "USD")

  # Guards on `is_list/1` because a product rendered without its variants
  # preloaded carries an `Ecto.Association.NotLoaded` struct, not a list. A
  # missing preload must degrade to "no price", never raise mid-render.
  def product_price(%Product{active_variants: variants} = product, currency)
      when is_list(variants) do
    case Cass.Catalog.cheapest_active_variant(product) do
      nil -> "Not available in #{currency}"
      variant -> money(variant.price_cents, variant.currency || currency)
    end
  end

  def product_price(_product, currency), do: "Not available in #{currency}"

  @doc "The cheapest and dearest active prices, as a display range."
  def price_range(variants) when is_list(variants) do
    prices =
      variants
      |> Enum.map(& &1.price_cents)
      |> Enum.reject(&is_nil/1)

    case Enum.uniq(prices) |> Enum.sort() do
      [] -> nil
      [only] -> only
      [lowest, _rest | _] = sorted -> {lowest, List.last(sorted)}
    end
  end

  def price_range(_), do: nil

  @doc """
  Formats a variant price range, collapsing a single price to itself:
  `{999, 999}` → `"USD 9.99"`, `{500, 2500}` → `"USD 5.00 – USD 25.00"`.
  """
  def price_range_label(variants) do
    case price_range(variants) do
      nil ->
        "Not available"

      lowest when is_integer(lowest) ->
        money(lowest, currency_of(variants))

      {lowest, highest} ->
        "#{money(lowest, currency_of(variants))} – #{money(highest, currency_of(variants))}"
    end
  end

  @doc "Renders a `DateTime` as `Month DD, YYYY`; anything else as `\"TBA\"`."
  def date(nil), do: "TBA"
  def date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%B %d, %Y")
  def date(%Date{} = date), do: Calendar.strftime(date, "%B %d, %Y")
  def date(_), do: "TBA"

  @doc "The short human label for a product type, used on cards and pages."
  def product_type_label(:digital), do: "Digital download"
  def product_type_label(:smm), do: "Social marketing"
  def product_type_label(:ai), do: "AI tool"
  def product_type_label(:service), do: "Service"
  def product_type_label(other), do: other |> to_string() |> String.replace("_", " ")

  @doc """
  The plural, shopper-facing heading for a product type, used by the landing
  page's "what you can buy" section.

  Distinct from `product_type_label/1`, which is the terse badge text shown on
  a single card.
  """
  def product_type_heading(:digital), do: "Digital products"
  def product_type_heading(:smm), do: "Social marketing services"
  def product_type_heading(:ai), do: "AI tools"
  def product_type_heading(:service), do: "Services"
  def product_type_heading(other), do: product_type_label(other)

  @doc "A one-line shopper-facing summary of what a product type offers."
  def product_type_blurb(:digital),
    do:
      "Templates, guides, code resources, and design assets delivered as secure downloads or account entitlements."

  def product_type_blurb(:smm),
    do:
      "Transparent content packages, campaign planning, analytics, and reporting — never fake engagement or deceptive automation."

  def product_type_blurb(:ai),
    do:
      "Quota-controlled utilities such as caption generation, SEO assistance, and product copy — routed through the Nexus AI Gateway."

  def product_type_blurb(:service),
    do: "Work delivered by an approved provider, tracked line by line from payment to completion."

  def product_type_blurb(_other),
    do: "Digital goods and services delivered through the CASS marketplace."

  @doc "The icon that stands for a product type across the storefront."
  def product_type_icon(:digital), do: "hero-arrow-down-tray"
  def product_type_icon(:smm), do: "hero-megaphone"
  def product_type_icon(:ai), do: "hero-sparkles"
  def product_type_icon(:service), do: "hero-wrench-screwdriver"
  def product_type_icon(_other), do: "hero-cube"

  @doc "A one-line plain description of how a product type is delivered."
  def delivery_hint(:digital), do: "Download and access code"
  def delivery_hint(:ai), do: "Quota-controlled AI access"
  def delivery_hint(:smm), do: "Service delivered by a provider"
  def delivery_hint(:service), do: "Delivered by a provider"
  def delivery_hint(_), do: nil

  defp currency_of(variants) do
    case Enum.find(variants, & &1.currency) do
      %{currency: currency} when is_binary(currency) -> currency
      _ -> "USD"
    end
  end
end
