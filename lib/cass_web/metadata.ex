defmodule CassWeb.Metadata do
  @moduledoc """
  Helpers that turn catalog records into SEO metadata values for the root
  layout. Titles/descriptions stored on the record win; otherwise we fall back
  to the name and a truncated copy of the description.
  """
  alias Cass.Catalog.{Category, Product}

  @default_description "CASS is a unified marketplace for digital products, compliant social marketing services, and AI-powered tools."

  @doc "Builds the page title used by the catalog LiveViews."
  def title(%Category{} = category), do: present(category.seo_title) || present(category.name)
  def title(%Product{} = product), do: present(product.seo_title) || present(product.name)

  @doc "Builds the meta description for a category page."
  def category_description(%Category{} = category) do
    present(category.seo_description) ||
      truncate(category.description || "", 160) ||
      @default_description
  end

  @doc "Builds the meta description for a product page."
  def product_description(%Product{} = product) do
    present(product.seo_description) ||
      present(product.short_description) ||
      truncate(product.description || "", 160) ||
      @default_description
  end

  defp truncate(text, max) when is_binary(text) do
    text = String.trim(text) |> String.replace(~r/\s+/, " ")

    if String.length(text) <= max do
      text
    else
      String.trim_trailing(String.slice(text, 0, max - 1)) <> "…"
    end
  end

  defp truncate(_, _), do: nil

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
