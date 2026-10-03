defmodule Cass.CatalogSearchTest do
  @moduledoc """
  Covers `Cass.Catalog.search_public_products/1` and
  `Cass.Catalog.list_public_featured_products/1`.

  The overriding concern is that a search may only ever *narrow* what
  `list_public_products/0` already exposes. Every visibility rule is layered on
  top of the same `public_product_query/1` predicate, and that shared origin is
  what these tests pin down.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope

  alias Cass.Catalog
  alias Cass.Catalog.SearchParams
  alias Cass.Repo

  defp slugs(%{products: products}), do: Enum.map(products, & &1.name)

  describe "visibility is never widened by a search" do
    setup do
      category = category_fixture()
      admin = admin_fixture()

      {:ok, public_product} =
        Catalog.create_product(category, %{
          name: "Public Item",
          slug: "public-item",
          product_type: :digital,
          visibility: :public
        })

      {:ok, public_product} = Catalog.publish_product(Scope.for_user(admin), public_product)

      {:ok, draft} =
        Catalog.create_product(category, %{
          name: "Draft Item",
          slug: "draft-item",
          product_type: :digital,
          visibility: :public
        })

      {:ok, private_product} =
        Catalog.create_product(category, %{
          name: "Private Item",
          slug: "private-item",
          product_type: :digital,
          visibility: :private
        })

      {:ok, private_product} = Catalog.publish_product(Scope.for_user(admin), private_product)

      {:ok, unlisted} =
        Catalog.create_product(category, %{
          name: "Unlisted Item",
          slug: "unlisted-item",
          product_type: :digital,
          visibility: :unlisted
        })

      {:ok, unlisted} = Catalog.publish_product(Scope.for_user(admin), unlisted)

      archived = category_fixture()

      {:ok, archived_category_product} =
        Catalog.create_product(archived, %{
          name: "Archived Category Item",
          slug: "archived-cat-item",
          product_type: :digital,
          visibility: :public
        })

      {:ok, archived_category_product} =
        Catalog.publish_product(Scope.for_user(admin), archived_category_product)

      {:ok, _archived} = Catalog.archive_category(archived)

      %{
        public_product: public_product,
        draft: draft,
        private_product: private_product,
        unlisted: unlisted,
        archived_category_product: archived_category_product
      }
    end

    test "an unfiltered search returns exactly the public index", _context do
      names = slugs(Catalog.search_public_products(%SearchParams{}))

      assert names == slugs(%{products: Catalog.list_public_products()})
      assert "Public Item" in names
    end

    test "drafts, private, unlisted and archived-category products are all excluded", context do
      names = slugs(Catalog.search_public_products(%SearchParams{}))

      hidden = [
        context.draft,
        context.private_product,
        context.unlisted,
        context.archived_category_product
      ]

      hidden_names = Enum.map(hidden, & &1.name)

      for name <- hidden_names do
        refute name in names, "expected #{inspect(name)} to be excluded from the public catalog"
      end
    end

    test "a search term cannot surface a hidden product either", context do
      for hidden <- [
            context.draft,
            context.private_product,
            context.unlisted,
            context.archived_category_product
          ] do
        result = Catalog.search_public_products(%SearchParams{query: hidden.name})

        assert result.total == 0,
               "searching for #{inspect(hidden.name)} leaked a product that is not publicly discoverable"
      end
    end

    test "a product scheduled for the future is not yet public" do
      category = category_fixture()
      {product, _variant} = published_variant_fixture(category, product_name: "Scheduled Item")

      future =
        product
        |> Ecto.Changeset.change(
          published_at:
            DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
        )
        |> Repo.update!()

      assert future.visibility == :public
      assert future.status == :published
      refute "Scheduled Item" in slugs(Catalog.search_public_products(%SearchParams{}))

      refute "Scheduled Item" in slugs(
               Catalog.search_public_products(%SearchParams{query: "Scheduled"})
             )

      # Once the scheduled date passes it becomes publicly discoverable, which
      # proves the row was excluded by the due date and not by some other
      # accident.
      product
      |> Ecto.Changeset.change(
        published_at:
          DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert "Scheduled Item" in slugs(Catalog.search_public_products(%SearchParams{}))
    end
  end

  describe "text search" do
    setup do
      category = category_fixture()

      {template_product, _} =
        published_variant_fixture(category, product_name: "Notion Template Pack")

      {ai_product, _} =
        published_variant_fixture(category, product_name: "Caption Generator", product_type: :ai)

      %{category: category, template_product: template_product, ai_product: ai_product}
    end

    test "matches on name, case-insensitively" do
      assert slugs(Catalog.search_public_products(%SearchParams{query: "notion"})) == [
               "Notion Template Pack"
             ]

      assert slugs(Catalog.search_public_products(%SearchParams{query: "NOTION"})) == [
               "Notion Template Pack"
             ]
    end

    test "matches on category name, so a product is findable through its shelf", %{
      category: category
    } do
      result = Catalog.search_public_products(%SearchParams{query: category.name})

      assert result.total > 0
      assert "Notion Template Pack" in slugs(result)
      assert "Caption Generator" in slugs(result)
    end

    test "a blank or whitespace term is ignored rather than matching nothing", %{
      category: category
    } do
      {plain, _} = published_variant_fixture(category, product_name: "Plain Item")
      assert plain

      assert Catalog.search_public_products(%SearchParams{query: "   "}).total ==
               Catalog.search_public_products(%SearchParams{}).total

      assert Catalog.search_public_products(%SearchParams{query: nil}).total ==
               Catalog.search_public_products(%SearchParams{}).total
    end

    test "LIKE wildcards in the term are escaped, so they cannot match everything" do
      result = Catalog.search_public_products(%SearchParams{query: "%"})
      assert result.total == 0

      underscore = Catalog.search_public_products(%SearchParams{query: "_"})
      assert underscore.total == 0
    end

    test "an over-long term is truncated instead of raising" do
      assert %{} =
               Catalog.search_public_products(%SearchParams{query: String.duplicate("a", 500)})
    end
  end

  describe "filters" do
    setup do
      category = category_fixture()

      {digital, _} =
        published_variant_fixture(category, product_name: "Digital Thing", product_type: :digital)

      {ai, _} = published_variant_fixture(category, product_name: "AI Thing", product_type: :ai)

      %{category: category, digital: digital, ai: ai}
    end

    test "product_type narrows results", %{category: _category} do
      result = Catalog.search_public_products(%SearchParams{product_type: :ai})
      assert "AI Thing" in slugs(result)
      refute "Digital Thing" in slugs(result)
      assert result.product_type == :ai
    end

    test "an unknown product_type collapses to no filter instead of raising" do
      result = Catalog.search_public_products(%SearchParams{product_type: :nonsense})

      assert result.product_type == nil
      assert result.total == Catalog.search_public_products(%SearchParams{}).total
    end

    test "category_slug narrows to that category", %{category: category} do
      result = Catalog.search_public_products(%SearchParams{category_slug: category.slug})
      assert result.total == 2
      assert result.category_slug == category.slug
    end

    test "an unknown category_slug returns nothing rather than everything" do
      result = Catalog.search_public_products(%SearchParams{category_slug: "no-such-category"})
      assert result.total == 0
      assert result.products == []
    end

    test "an archived category's slug returns nothing" do
      archived = category_fixture()
      {product, _} = published_variant_fixture(archived, product_name: "Doomed Item")
      {:ok, _} = Catalog.archive_category(archived)

      assert Catalog.search_public_products(%SearchParams{category_slug: archived.slug}).total ==
               0

      assert Catalog.search_public_products(%SearchParams{query: "Doomed Item"}).total == 0
      assert product.status == :published
    end
  end

  describe "sorting" do
    setup do
      category = category_fixture()

      {cheap, _} =
        published_variant_fixture(category, product_name: "Cheap Item", price_cents: 100)

      {mid, _} = published_variant_fixture(category, product_name: "Mid Item", price_cents: 500)
      {rich, _} = published_variant_fixture(category, product_name: "Rich Item", price_cents: 900)

      %{category: category, cheap: cheap, mid: mid, rich: rich}
    end

    test "price_asc sorts by the cheapest active variant" do
      names = slugs(Catalog.search_public_products(%SearchParams{sort: "price_asc"}))
      assert Enum.take(names, 3) == ["Cheap Item", "Mid Item", "Rich Item"]
    end

    test "price_desc sorts by the richest active variant" do
      names = slugs(Catalog.search_public_products(%SearchParams{sort: "price_desc"}))
      assert Enum.take(names, 3) == ["Rich Item", "Mid Item", "Cheap Item"]
    end

    test "name_asc and name_desc are opposites" do
      asc = slugs(Catalog.search_public_products(%SearchParams{sort: "name_asc"}))
      desc = slugs(Catalog.search_public_products(%SearchParams{sort: "name_desc"}))

      assert Enum.take(asc, 3) == ["Cheap Item", "Mid Item", "Rich Item"]
      assert Enum.take(desc, 3) == ["Rich Item", "Mid Item", "Cheap Item"]
    end

    test "an unknown sort key falls back to newest" do
      result =
        Catalog.search_public_products(%SearchParams{sort: "'; DROP TABLE cass_products; --"})

      assert result.sort == "newest"
      assert result.total == Catalog.search_public_products(%SearchParams{sort: "newest"}).total
    end

    test "price ordering puts products with no active variant last, in both directions" do
      category = category_fixture()

      {:ok, variantless} =
        Catalog.create_product(category, %{
          name: "Variantless Item",
          slug: "variantless-item",
          product_type: :digital,
          visibility: :public
        })

      admin = Scope.for_user(admin_fixture())
      {:ok, _variantless} = Catalog.publish_product(admin, variantless)

      asc = slugs(Catalog.search_public_products(%SearchParams{sort: "price_asc"}))
      desc = slugs(Catalog.search_public_products(%SearchParams{sort: "price_desc"}))

      assert List.last(asc) == "Variantless Item"
      assert List.last(desc) == "Variantless Item"
    end

    test "sorting is stable, so paging never repeats or drops a row" do
      category = category_fixture()

      for index <- 1..7 do
        # Deliberately identical prices: without a unique tiebreaker every page
        # boundary would be free to reorder these.
        published_variant_fixture(category, product_name: "Same Price #{index}", price_cents: 777)
      end

      page_size = 2
      # The setup block contributes three more products at distinct prices, so
      # the full result is ten rows: five pages of two. Paging exactly to the
      # end is what proves no row is dropped at a boundary.
      total = Catalog.search_public_products(%SearchParams{sort: "price_asc", per_page: 2}).total
      assert total == 10

      pages =
        1..div(total, page_size)
        |> Enum.map(
          &Catalog.search_public_products(%SearchParams{
            sort: "price_asc",
            per_page: page_size,
            page: &1
          })
        )
        |> Enum.flat_map(& &1.products)

      names = Enum.map(pages, & &1.name)

      assert length(names) == length(Enum.uniq(names)), "a product appeared on two pages"
      assert "Same Price 1" in names
      assert "Same Price 7" in names
    end
  end

  describe "pagination" do
    setup do
      category = category_fixture()

      for index <- 1..5 do
        published_variant_fixture(category, product_name: "Page Item #{index}")
      end

      %{category: category}
    end

    test "total_pages is derived from the total and the page size" do
      result = Catalog.search_public_products(%SearchParams{per_page: 2})

      assert result.total == 5
      assert result.total_pages == 3
      assert length(result.products) == 2
    end

    test "the final page is partial and the past-the-end page is empty" do
      last = Catalog.search_public_products(%SearchParams{per_page: 2, page: 3})
      assert length(last.products) == 1

      beyond = Catalog.search_public_products(%SearchParams{per_page: 2, page: 99})
      assert beyond.products == []
      assert beyond.total == 5
    end

    test "an empty result set still reports one page" do
      result = Catalog.search_public_products(%SearchParams{query: "no-such-product-anywhere"})

      assert result.total == 0
      assert result.products == []
      assert result.total_pages == 1
    end

    test "out-of-range page and per_page values are clamped, not trusted" do
      assert Catalog.search_public_products(%SearchParams{page: -5}).page == 1
      assert Catalog.search_public_products(%SearchParams{page: 0}).page == 1
      assert Catalog.search_public_products(%SearchParams{per_page: 0}).per_page == 1
      assert Catalog.search_public_products(%SearchParams{per_page: 10_000}).per_page == 48
    end
  end

  describe "list_public_featured_products/1" do
    test "returns flagged products first" do
      category = category_fixture()
      admin = Scope.for_user(admin_fixture())

      {:ok, plain} =
        Catalog.create_product(category, %{
          name: "Plain Shelf Item",
          slug: "plain-shelf-item",
          product_type: :digital,
          visibility: :public
        })

      {:ok, plain} = Catalog.publish_product(admin, plain)
      refute plain.featured

      {:ok, flagged} =
        Catalog.create_product(category, %{
          name: "Flagged Shelf Item",
          slug: "flagged-shelf-item",
          product_type: :digital,
          visibility: :public,
          featured: true
        })

      {:ok, flagged} = Catalog.publish_product(admin, flagged)
      assert flagged.featured

      names = Enum.map(Catalog.list_public_featured_products(8), & &1.name)

      # The shelf shows flagged products, and only those, while any exist.
      assert names == ["Flagged Shelf Item"]
    end

    test "not being flagged never removes a product from the catalog" do
      category = category_fixture()
      admin = Scope.for_user(admin_fixture())

      {:ok, unflagged} =
        Catalog.create_product(category, %{
          name: "Unflagged Public Item",
          slug: "unflagged-public-item",
          product_type: :digital,
          visibility: :public
        })

      {:ok, unflagged} = Catalog.publish_product(admin, unflagged)
      refute unflagged.featured

      assert "Unflagged Public Item" in slugs(Catalog.search_public_products(%SearchParams{}))

      assert "Unflagged Public Item" in slugs(
               Catalog.search_public_products(%SearchParams{sort: "featured"})
             )
    end

    test "never returns unpublished or hidden products" do
      category = category_fixture()
      admin = Scope.for_user(admin_fixture())

      {:ok, draft} =
        Catalog.create_product(category, %{
          name: "Draft Shelf Item",
          slug: "draft-shelf-item",
          product_type: :digital,
          visibility: :public
        })

      {:ok, hidden} =
        Catalog.create_product(category, %{
          name: "Hidden Shelf Item",
          slug: "hidden-shelf-item",
          product_type: :digital,
          visibility: :private
        })

      {:ok, hidden} = Catalog.publish_product(admin, hidden)

      names = Enum.map(Catalog.list_public_featured_products(24), & &1.name)

      refute draft.name in names
      refute hidden.name in names
    end

    test "falls back to the newest public products when nothing is featured" do
      category = category_fixture()
      {product, _} = published_variant_fixture(category, product_name: "Unflagged Shelf Item")

      names = Enum.map(Catalog.list_public_featured_products(8), & &1.name)

      assert "Unflagged Shelf Item" in names
      assert product.visibility == :public
    end

    test "honours the limit" do
      category = category_fixture()

      for index <- 1..5,
          do: published_variant_fixture(category, product_name: "Limit Item #{index}")

      assert length(Catalog.list_public_featured_products(3)) == 3
    end
  end
end
