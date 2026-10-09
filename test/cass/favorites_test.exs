defmodule Cass.FavoritesTest do
  @moduledoc """
  The favorites context: the (user, product) pin, its scoping, idempotency,
  and how listing re-validates against the public catalog contract.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Favorites

  setup do
    scope = Scope.for_user(user_fixture())
    other_scope = Scope.for_user(user_fixture())
    admin = Scope.for_user(admin_fixture())

    {:ok, category} = Catalog.create_category(%{name: "Digital", slug: "digital"})

    {:ok, draft} =
      Catalog.create_product(category, %{
        name: "Draft Product",
        slug: "draft-product",
        product_type: :digital,
        visibility: :public
      })

    {:ok, product_a} =
      Catalog.create_product(category, %{
        name: "Product A",
        slug: "product-a",
        product_type: :digital,
        visibility: :public
      })

    {:ok, product_a} = Catalog.publish_product(admin, product_a)

    {:ok, product_b} =
      Catalog.create_product(category, %{
        name: "Product B",
        slug: "product-b",
        product_type: :digital,
        visibility: :public
      })

    {:ok, product_b} = Catalog.publish_product(admin, product_b)

    %{
      scope: scope,
      other_scope: other_scope,
      admin: admin,
      product_a: product_a,
      product_b: product_b,
      draft: draft
    }
  end

  test "a guest has no favorites and cannot save", %{product_a: product_a} do
    guest = Scope.for_user(nil)

    assert Favorites.list_favorite_products(guest) == []
    assert Favorites.favorite_ids_for(guest) == []
    refute Favorites.favorited?(guest, product_a.id)

    assert {:error, changeset} = Favorites.add_favorite(guest, product_a)
    assert "you must be signed in to save a product" in errors_on(changeset).base
  end

  test "saving is idempotent and scoped to the account", %{
    scope: scope,
    other_scope: other_scope,
    product_a: product_a
  } do
    assert {:ok, favorite} = Favorites.add_favorite(scope, product_a)
    assert favorite.user_id == scope.user.id

    assert {:ok, same} = Favorites.add_favorite(scope, product_a)
    assert same.id == favorite.id

    assert Favorites.favorited?(scope, product_a.id)
    assert Favorites.favorite_ids_for(scope) == [product_a.id]
    assert [listed] = Favorites.list_favorite_products(scope)
    assert listed.id == product_a.id

    refute Favorites.favorited?(other_scope, product_a.id)
    assert Favorites.favorite_ids_for(other_scope) == []
    assert Favorites.list_favorite_products(other_scope) == []
  end

  test "removing is idempotent", %{scope: scope, product_a: product_a} do
    assert {:ok, _} = Favorites.add_favorite(scope, product_a)

    assert :ok = Favorites.remove_favorite(scope, product_a)
    assert :ok = Favorites.remove_favorite(scope, product_a)

    refute Favorites.favorited?(scope, product_a.id)
    assert Favorites.list_favorite_products(scope) == []
  end

  test "listing is most-recent-first and only returns public products", %{
    scope: scope,
    product_a: product_a,
    product_b: product_b,
    draft: draft
  } do
    Favorites.add_favorite(scope, product_b)
    Favorites.add_favorite(scope, product_a)
    Favorites.add_favorite(scope, draft)

    assert [first, second] = Favorites.list_favorite_products(scope)
    # product_a was saved last, so it leads the list.
    assert first.id == product_a.id
    assert second.id == product_b.id

    # The pin for the unpublished draft is kept, but never listed.
    assert length(Favorites.favorite_ids_for(scope)) == 3
  end

  test "an archived product drops out of the list", %{
    scope: scope,
    admin: admin,
    product_a: product_a,
    product_b: product_b
  } do
    Favorites.add_favorite(scope, product_b)
    Favorites.add_favorite(scope, product_a)

    {:ok, _archived} = Catalog.archive_product(admin, product_b)

    assert [listed] = Favorites.list_favorite_products(scope)
    assert listed.id == product_a.id
  end
end
