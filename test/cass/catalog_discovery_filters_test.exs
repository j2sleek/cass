defmodule Cass.CatalogDiscoveryFiltersTest do
  @moduledoc """
  The catalog's discovery filters are pure functions over an already-loaded
  product list (see `Cass.Catalog`'s "Discovery filters" section), so they are
  exercised here against real published products rather than mocks.

  The invariants under test are the ones the storefront depends on:

    * a filter can only ever narrow to something the buyer can actually see —
      the same "From $X" price the card shows, and the same stock rule the buy
      button uses
    * every filter is total: an empty or out-of-vocabulary argument means "no
      filter", never an exception and never a widened result
  """
  use Cass.DataCase

  import Cass.AccountsFixtures

  alias Cass.Accounts.Scope
  alias Cass.Catalog

  setup do
    admin = admin_fixture()
    admin_scope = Scope.for_user(admin)
    {:ok, category} = Catalog.create_category(%{name: "Media", slug: "media"})

    # Publishes a public product with the given type and variants. A variant of
    # `active: false` or a product with no variants at all are both realistic
    # storefront states, so the helper has to be able to express them.
    publish = fn name, slug, type, variants ->
      {:ok, product} =
        Catalog.create_product(category, %{
          name: name,
          slug: slug,
          product_type: type,
          visibility: :public
        })

      {:ok, published} = Catalog.publish_product(admin_scope, product)

      variants
      |> Enum.with_index()
      |> Enum.each(fn {variant, index} ->
        {:ok, _} =
          Catalog.create_variant(
            admin_scope,
            published,
            Map.put(variant, :sku, "#{slug}-#{index}")
          )
      end)

      published
    end

    %{publish: publish}
  end

  defp variant(attrs) do
    Map.merge(
      %{name: "Standard", price_cents: 1_000, currency: "USD", stock: 5, active: true},
      attrs
    )
  end

  defp slugs(products), do: Enum.map(products, & &1.slug)

  describe "product_type_counts/1" do
    test "lists every vocabulary member, zeros included", %{publish: publish} do
      publish.("An Ebook", "an-ebook", :digital, [variant(%{})])
      publish.("A Poster", "a-poster", :physical, [variant(%{})])

      counts = Catalog.product_type_counts(Catalog.list_public_products([]))

      assert counts.digital == 1
      assert counts.physical == 1
      assert counts.smm == 0
      assert counts.ai == 0
      assert counts.service == 0

      # The keys are exactly the closed vocabulary, so the chips on the page
      # can never render a type the catalog cannot hold.
      assert Map.keys(counts) |> Enum.sort() == Catalog.product_types() |> Enum.sort()
    end

    test "counts an empty list as all zeros" do
      assert Catalog.product_type_counts([]) == Map.new(Catalog.product_types(), &{&1, 0})
    end
  end

  describe "filter_by_product_types/2" do
    setup %{publish: publish} do
      publish.("An Ebook", "an-ebook", :digital, [variant(%{})])
      publish.("A Poster", "a-poster", :physical, [variant(%{})])
      %{products: Catalog.list_public_products([])}
    end

    test "keeps only the requested vocabulary members", %{products: products} do
      assert products |> Catalog.filter_by_product_types([:physical]) |> slugs() == ["a-poster"]

      assert products
             |> Catalog.filter_by_product_types([:digital, :physical])
             |> slugs()
             |> Enum.sort() == ["a-poster", "an-ebook"]
    end

    test "an empty list is the no-filter case and preserves the caller's order", %{
      products: products
    } do
      assert Catalog.filter_by_product_types(products, []) == products
    end

    test "anything outside the vocabulary is ignored rather than raising", %{products: products} do
      # The public layer normalises to atoms first, so this only has to be
      # harmless — a string or an unknown atom must not match, and must not
      # widen the result set to everything either.
      assert Catalog.filter_by_product_types(products, ["physical"]) == products
      assert Catalog.filter_by_product_types(products, [:not_a_type]) == products
    end

    test "selecting a type with no products narrows to nothing", %{products: products} do
      assert Catalog.filter_by_product_types(products, [:service]) == []
    end
  end

  describe "lowest_price_cents/1 and filter_by_price_band/3" do
    setup %{publish: publish} do
      publish.("Cheap", "cheap", :digital, [
        variant(%{name: "Big", price_cents: 9_000}),
        variant(%{name: "Small", price_cents: 500})
      ])

      publish.("Pricy", "pricy", :digital, [variant(%{price_cents: 4_000})])
      publish.("Priceless", "priceless", :digital, [])

      %{products: Catalog.list_public_products([])}
    end

    test "the lowest price is the cheapest active variant", %{products: products} do
      cheap = Enum.find(products, &(&1.slug == "cheap"))

      assert Catalog.lowest_price_cents(cheap) == 500
    end

    test "a product with no active variant has no price", %{products: products} do
      priceless = Enum.find(products, &(&1.slug == "priceless"))

      assert Catalog.lowest_price_cents(priceless) == nil
    end

    test "no bounds is a no-op", %{products: products} do
      assert products |> Catalog.filter_by_price_band(nil, nil) |> slugs() |> Enum.sort() ==
               ["cheap", "priceless", "pricy"]
    end

    test "a lower bound keeps products starting at or above it", %{products: products} do
      assert products |> Catalog.filter_by_price_band(1_000, nil) |> slugs() == ["pricy"]
    end

    test "an upper bound keeps products starting at or below it", %{products: products} do
      assert products
             |> Catalog.filter_by_price_band(nil, 4_000)
             |> slugs()
             |> Enum.sort() == ["cheap", "pricy"]
    end

    test "both bounds form an inclusive band", %{products: products} do
      assert products
             |> Catalog.filter_by_price_band(500, 4_000)
             |> slugs()
             |> Enum.sort() == ["cheap", "pricy"]

      assert products |> Catalog.filter_by_price_band(501, 3_999) |> slugs() == []
    end

    test "an active band excludes a product that has no price yet", %{products: products} do
      refute "priceless" in (products |> Catalog.filter_by_price_band(0, nil) |> slugs())
    end
  end

  describe "in_stock?/1 and filter_by_stock/2" do
    setup %{publish: publish} do
      publish.("Unlimited", "unlimited", :digital, [variant(%{stock: nil})])
      publish.("In Stock", "in-stock", :digital, [variant(%{stock: 3})])
      publish.("Sold Out", "sold-out", :digital, [variant(%{stock: 0})])
      publish.("No Tier Yet", "no-tier-yet", :digital, [])

      # An inactive variant is not purchasable, so it cannot make a product
      # available even though its stock counter is positive.
      publish.("Inactive Only", "inactive-only", :digital, [variant(%{stock: 9, active: false})])

      %{products: Catalog.list_public_products([])}
    end

    test "a nil stock means unlimited supply", %{products: products} do
      unlimited = Enum.find(products, &(&1.slug == "unlimited"))

      assert Catalog.in_stock?(unlimited)
    end

    test "a zero stock is sold out", %{products: products} do
      sold_out = Enum.find(products, &(&1.slug == "sold-out"))

      refute Catalog.in_stock?(sold_out)
    end

    test "only active variants count toward availability", %{products: products} do
      inactive_only = Enum.find(products, &(&1.slug == "inactive-only"))

      refute Catalog.in_stock?(inactive_only)
    end

    test "true keeps only what can be bought right now", %{products: products} do
      assert products |> Catalog.filter_by_stock(true) |> slugs() |> Enum.sort() ==
               ["in-stock", "unlimited"]
    end

    test "false is the browsing default and a no-op", %{products: products} do
      assert Catalog.filter_by_stock(products, false) == products
    end
  end

  describe "filters compose" do
    test "type, price, and stock narrow together", %{publish: publish} do
      publish.("Cheap Digital", "cheap-digital", :digital, [variant(%{price_cents: 500})])
      publish.("Cheap Physical", "cheap-physical", :physical, [variant(%{price_cents: 500})])
      publish.("Pricy Digital", "pricy-digital", :digital, [variant(%{price_cents: 90_000})])

      publish.("Sold Out Digital", "sold-out-digital", :digital, [
        variant(%{price_cents: 500, stock: 0})
      ])

      result =
        Catalog.list_public_products([])
        |> Catalog.filter_by_price_band(nil, 1_000)
        |> Catalog.filter_by_stock(true)
        |> Catalog.filter_by_product_types([:digital])

      assert slugs(result) == ["cheap-digital"]
    end

    test "facets ignore the type filter but respect the others", %{publish: publish} do
      publish.("Cheap Digital", "cheap-digital", :digital, [variant(%{price_cents: 500})])
      publish.("Pricy Digital", "pricy-digital", :digital, [variant(%{price_cents: 90_000})])
      publish.("Cheap Physical", "cheap-physical", :physical, [variant(%{price_cents: 500})])

      base =
        Catalog.list_public_products([])
        |> Catalog.filter_by_price_band(nil, 1_000)

      counts = Catalog.product_type_counts(base)

      # Both types are still offered, because the price band was applied and the
      # type facet deliberately was not — that is what makes a chip's count the
      # answer to "how many would I get if I picked it?".
      assert counts.digital == 1
      assert counts.physical == 1
    end
  end
end
