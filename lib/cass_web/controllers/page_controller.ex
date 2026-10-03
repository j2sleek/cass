defmodule CassWeb.PageController do
  use CassWeb, :controller

  alias Cass.Catalog

  @default_description "CASS is a unified marketplace for digital products, compliant social marketing services, and AI-powered tools."

  def home(conn, _params) do
    render(conn, :home,
      page_title: "CASS · Unified Marketplace",
      meta_description: @default_description,
      canonical_url: CassWeb.Endpoint.url() <> ~p"/",
      categories: Catalog.list_public_categories(),
      featured_products: Catalog.list_public_featured_products(8),
      latest_products: Catalog.list_public_products() |> Enum.take(8),
      product_types: Catalog.product_types()
    )
  end
end
