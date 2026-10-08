defmodule CassWeb.AnalyticsInstrumentationTest do
  use CassWeb.ConnCase

  import Cass.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Cass.Accounts.Scope
  alias Cass.Analytics
  alias Cass.Catalog

  setup do
    admin_scope = Scope.for_user(admin_fixture())

    {:ok, category} =
      Catalog.create_category(%{name: "Digital Products", slug: "digital-products"})

    {:ok, product} =
      Catalog.create_product(category, %{
        name: "Sample Product",
        slug: "sample-product",
        product_type: :digital,
        visibility: :public,
        short_description: "A short blurb.",
        description: "A longer product description."
      })

    {:ok, published} = Catalog.publish_product(admin_scope, product)
    %{published: published}
  end

  test "a catalog search records a search event with the query and result count" do
    {:ok, view, _html} = live(build_conn(), ~p"/catalog?q=sample")

    assert has_element?(view, "h1", "Catalog")
    assert [event] = Analytics.list_events(name: "search")
    assert event.metadata["query"] == "sample"
    assert is_integer(event.metadata["result_count"])
  end

  test "viewing a product records a product_view event", %{published: product} do
    {:ok, _view, _html} = live(build_conn(), ~p"/catalog/products/sample-product")

    assert [event] = Analytics.list_events(name: "product_view")
    assert event.subject_type == "product"
    assert event.subject_id == to_string(product.id)
    assert event.metadata["title"] == "Sample Product"
  end
end
