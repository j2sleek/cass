defmodule CassWeb.ProductCardTest do
  @moduledoc """
  The public seller identity a product card renders: an approved vendor's
  display name, the email-derived fallback otherwise, and "Sold by CASS" for a
  platform-owned product.
  """
  use CassWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Cass.AccountsFixtures
  import Cass.CommerceFixtures, only: [category_fixture: 0]

  alias Cass.Accounts.Scope
  alias Cass.Catalog

  test "shows the approved vendor display name" do
    vendor = user_fixture()
    approved_vendor_profile_fixture(vendor, %{display_name: "Ada's Shop"})

    product = published_owned_product(vendor, "handmade-prints")

    assert visible_text(render_card(product)) =~ "Sold by Ada's Shop"
  end

  test "falls back to the email handle when the seller has no approved name" do
    owner = admin_fixture()
    vendor_profile_fixture(owner, %{display_name: "Pending Shop"})

    product = published_owned_product(owner, "pending-shop-widget")

    text = visible_text(render_card(product))
    assert text =~ "Sold by #{email_handle(owner.email)}"
    refute text =~ "Pending Shop"
  end

  test "shows 'Sold by CASS' for a platform-owned product" do
    {:ok, product} =
      Catalog.create_product(category_fixture(), %{
        name: "Platform Widget",
        slug: "platform-widget",
        product_type: :digital,
        visibility: :public
      })

    {:ok, _published} = Catalog.publish_platform_product(product)

    assert render_card(Catalog.get_public_product_by_slug("platform-widget")) =~ "Sold by CASS"
  end

  # Builds a public product owned by `owner`, exercising the real public query so
  # the card is rendered from exactly what a storefront page would receive.
  defp published_owned_product(owner, slug) do
    scope = Scope.for_user(owner)
    unique = System.unique_integer([:positive])

    {:ok, product} =
      Catalog.create_owned_product(scope, category_fixture(), %{
        name: "Widget #{unique}",
        slug: slug,
        product_type: :digital,
        visibility: :public
      })

    {:ok, _published} = Catalog.publish_product(scope, product)

    {:ok, _variant} =
      Catalog.create_variant(scope, product, %{
        name: "Default",
        sku: "SKU-#{unique}",
        price_cents: 499,
        currency: "USD",
        stock: 10
      })

    Catalog.get_public_product_by_slug(slug)
  end

  defp render_card(product) do
    render_component(&CassWeb.ProductCard.product_card/1, product: product)
  end

  # The card is an HTML fragment with escaped entities (an apostrophe renders as
  # `&#39;`), so compare against its decoded visible text rather than raw markup.
  defp visible_text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text()

  defp email_handle(email), do: email |> String.split("@", parts: 2) |> hd()
end
