defmodule CassWeb.PageController do
  use CassWeb, :controller

  @default_description "CASS is a unified marketplace for digital products, compliant social marketing services, and AI-powered tools."

  def home(conn, _params) do
    render(conn, :home,
      page_title: "CASS · Unified Marketplace",
      meta_description: @default_description,
      canonical_url: CassWeb.Endpoint.url() <> ~p"/"
    )
  end
end
