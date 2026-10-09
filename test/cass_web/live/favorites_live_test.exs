defmodule CassWeb.FavoritesLiveTest do
  @moduledoc """
  The signed-in favorites page (`/favorites`): authorization, the list of
  saved products, and removal from the list.
  """
  use CassWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Favorites

  setup do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: build_conn()})
    admin = Scope.for_user(admin_fixture())

    {:ok, category} = Catalog.create_category(%{name: "Digital", slug: "digital"})

    {:ok, product} =
      Catalog.create_product(category, %{
        name: "Pinned Product",
        slug: "pinned-product",
        product_type: :digital,
        visibility: :public,
        short_description: "A short blurb."
      })

    {:ok, product} = Catalog.publish_product(admin, product)

    %{conn: conn, user: user, admin: admin, product: product}
  end

  test "guests are redirected to the login page" do
    conn = get(build_conn(), ~p"/favorites")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "shows an empty state with a path into the catalog when nothing is saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/favorites")

    assert has_element?(view, "#favorites-heading", "Favorites")
    assert has_element?(view, "#favorites-empty")
    assert has_element?(view, "#favorites-empty a[href='/catalog']")
  end

  test "lists saved products and removes one", %{conn: conn, user: user, product: product} do
    Favorites.add_favorite(Scope.for_user(user), product)

    {:ok, view, _html} = live(conn, ~p"/favorites")

    assert has_element?(view, "#favorite-#{product.id}")
    assert has_element?(view, "a[href='/catalog/products/pinned-product']")
    refute has_element?(view, "#favorites-empty")

    view
    |> element("#favorite-remove-#{product.id}")
    |> render_click()

    refute has_element?(view, "#favorite-#{product.id}")
    assert has_element?(view, "#favorites-empty")
    assert has_element?(view, "nav[aria-label='Primary mobile'] #tab-favorites")
  end
end
