defmodule CassWeb.ProductFavoritesTest do
  @moduledoc """
  The favorite toggle on the public product page: who sees it, what it does,
  and the analytics events it records.
  """
  use CassWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Cass.Accounts.Scope
  alias Cass.Analytics
  alias Cass.Catalog
  alias Cass.Favorites

  setup do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: build_conn()})
    admin = Scope.for_user(admin_fixture())

    {:ok, category} = Catalog.create_category(%{name: "Digital", slug: "digital"})

    {:ok, product} =
      Catalog.create_product(category, %{
        name: "Pinnable Product",
        slug: "pinnable-product",
        product_type: :digital,
        visibility: :public,
        short_description: "A short blurb.",
        description: "A longer product description."
      })

    {:ok, product} = Catalog.publish_product(admin, product)

    %{conn: conn, user: user, product: product}
  end

  test "guests see no favorite toggle on the product page" do
    {:ok, view, _html} = live(build_conn(), ~p"/catalog/products/pinnable-product")

    refute has_element?(view, "#favorite-toggle")
  end

  test "a signed-in visitor can save and un-save a product", %{
    conn: conn,
    user: user,
    product: product
  } do
    {:ok, view, _html} = live(conn, ~p"/catalog/products/pinnable-product")

    refute has_element?(view, "#favorite-toggle[aria-pressed='true']")
    assert has_element?(view, "#favorite-toggle[aria-pressed='false']")

    view
    |> element("#favorite-toggle")
    |> render_click()

    assert has_element?(view, "#favorite-toggle[aria-pressed='true']")
    assert has_element?(view, "#favorite-toggle", "Saved to favorites")
    assert Favorites.favorited?(Scope.for_user(user), product.id)

    view
    |> element("#favorite-toggle")
    |> render_click()

    assert has_element?(view, "#favorite-toggle[aria-pressed='false']")
    refute Favorites.favorited?(Scope.for_user(user), product.id)
  end

  test "toggling favorites records favorite_added and favorite_removed events", %{
    conn: conn,
    product: product
  } do
    {:ok, view, _html} = live(conn, ~p"/catalog/products/pinnable-product")

    view
    |> element("#favorite-toggle")
    |> render_click()

    assert [added] = Analytics.list_events(name: "favorite_added")
    assert added.subject_type == "product"
    assert added.subject_id == to_string(product.id)
    assert added.metadata["title"] == "Pinnable Product"

    view
    |> element("#favorite-toggle")
    |> render_click()

    assert [removed] = Analytics.list_events(name: "favorite_removed")
    assert removed.subject_id == to_string(product.id)
    assert removed.metadata["title"] == "Pinnable Product"
  end
end
