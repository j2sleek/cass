defmodule CassWeb.CatalogFiltersTest do
  @moduledoc """
  The catalog's discovery UI: product-type facets, the in-stock toggle, and the
  price band.

  Every control here is URL state, so the tests assert on both halves of the
  contract — what the grid shows, and the query string a shared link or the back
  button would reproduce.
  """
  use CassWeb.ConnCase

  import Cass.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Cass.Accounts.Scope
  alias Cass.Catalog

  @all_products ["ai-assistant", "digital-starter", "physical-poster", "sold-out-digital"]

  setup do
    admin = admin_fixture()
    admin_scope = Scope.for_user(admin)
    {:ok, category} = Catalog.create_category(%{name: "Media", slug: "media"})

    publish = fn name, slug, type, price_cents, stock ->
      {:ok, product} =
        Catalog.create_product(category, %{
          name: name,
          slug: slug,
          product_type: type,
          visibility: :public
        })

      {:ok, published} = Catalog.publish_product(admin_scope, product)

      {:ok, _} =
        Catalog.create_variant(admin_scope, published, %{
          name: "Standard",
          sku: "SKU-#{slug}",
          price_cents: price_cents,
          currency: "USD",
          stock: stock,
          active: true
        })

      published
    end

    # $10 digital, $25 physical, $120 AI, and a $30 digital that is sold out.
    publish.("Digital Starter", "digital-starter", :digital, 1_000, 5)
    publish.("Physical Poster", "physical-poster", :physical, 2_500, 5)
    publish.("AI Assistant", "ai-assistant", :ai, 12_000, 5)
    publish.("Sold Out Digital", "sold-out-digital", :digital, 3_000, 0)

    :ok
  end

  defp product_hrefs(view) do
    view
    |> render()
    |> then(&Regex.scan(~r{href="/catalog/products/([a-z0-9-]+)"}, &1))
    |> Enum.map(fn [_, slug] -> slug end)
    |> Enum.sort()
  end

  defp chip_text(view, selector) do
    element(view, selector)
    |> render()
    |> String.replace(~r/<\/?[^>]+>/, "")
  end

  describe "product type facets" do
    test "every vocabulary type gets a chip, with the count it would return" do
      {:ok, view, _html} = live(build_conn(), "/catalog")

      assert has_element?(view, "#type-all")
      assert has_element?(view, "#type-digital")
      assert has_element?(view, "#type-physical")
      assert has_element?(view, "#type-ai")
      assert has_element?(view, "#type-smm")
      assert has_element?(view, "#type-service")

      # Two digital products are published, and one of them is what a click on
      # the Digital chip would add to the grid.
      assert chip_text(view, "#type-digital") =~ "Digital"
      assert chip_text(view, "#type-digital") =~ "2"
      assert chip_text(view, "#type-physical") =~ "1"
      # A type with nothing published still shows, so the shelf never looks
      # broken — it is simply empty.
      assert chip_text(view, "#type-smm") =~ "0"
    end

    test "clicking a chip filters the grid and records the state in the URL" do
      {:ok, view, _html} = live(build_conn(), "/catalog")

      view |> element("#type-physical") |> render_click()

      assert_patch(view, "/catalog?types=physical")
      assert product_hrefs(view) == ["physical-poster"]
      assert has_element?(view, "h2", "Filtered results")
      assert has_element?(view, "#filter-summary")
      assert has_element?(view, "#type-physical[aria-pressed=\"true\"]")
    end

    test "clicking a second chip widens the selection" do
      {:ok, view, _html} = live(build_conn(), "/catalog")

      view |> element("#type-digital") |> render_click()
      view |> element("#type-ai") |> render_click()

      # Types are stored in vocabulary order, not click order, so the same
      # selection always produces the same shareable URL.
      assert_patch(view, "/catalog?types=digital,ai")
      assert product_hrefs(view) == ["ai-assistant", "digital-starter", "sold-out-digital"]
    end

    test "clicking a selected chip removes it" do
      {:ok, view, _html} = live(build_conn(), "/catalog?types=physical")

      view |> element("#type-physical") |> render_click()

      assert_patch(view, "/catalog")
      assert product_hrefs(view) == @all_products
      refute has_element?(view, "#filter-summary")
    end

    test "the All chip clears the type selection but keeps nothing else" do
      {:ok, view, _html} = live(build_conn(), "/catalog?types=physical,ai")

      view |> element("#type-all") |> render_click()

      assert_patch(view, "/catalog")
      assert product_hrefs(view) == @all_products
    end

    test "the summary chips can remove one type at a time" do
      {:ok, view, _html} = live(build_conn(), "/catalog?types=digital,physical")

      assert has_element?(view, "#filter-summary")

      view |> element("#remove-type-physical") |> render_click()

      assert_patch(view, "/catalog?types=digital")
      assert product_hrefs(view) == ["digital-starter", "sold-out-digital"]
    end

    test "a facet with nothing to show renders the filter empty state" do
      {:ok, view, _html} = live(build_conn(), "/catalog?types=service")

      assert has_element?(view, "h2", "Filtered results")
      assert render(view) =~ "No products match these filters"
    end
  end

  describe "availability" do
    test "the in-stock toggle hides sold-out products" do
      {:ok, view, _html} = live(build_conn(), "/catalog")

      view |> element("#stock-toggle") |> render_click()

      assert_patch(view, "/catalog?stock=in")
      refute "sold-out-digital" in product_hrefs(view)
      assert has_element?(view, "#stock-toggle[aria-pressed=\"true\"]")
      assert has_element?(view, "#filter-summary")
    end

    test "toggling it back off restores the catalog" do
      {:ok, view, _html} = live(build_conn(), "/catalog?stock=in")

      refute "sold-out-digital" in product_hrefs(view)

      view |> element("#stock-toggle") |> render_click()

      assert_patch(view, "/catalog")
      assert product_hrefs(view) == @all_products
    end
  end

  describe "price band" do
    test "submitting the form narrows by the price the card shows" do
      {:ok, view, _html} = live(build_conn(), "/catalog")

      view
      |> element("#catalog-price-form")
      |> render_submit(%{"min_price" => "10", "max_price" => "30"})

      assert_patch(view, "/catalog?min_price=10&max_price=30")
      # $10, $25, and $30 are in; the $120 AI tool is out.
      assert product_hrefs(view) == ["digital-starter", "physical-poster", "sold-out-digital"]
    end

    test "the typed value round-trips back into the field" do
      {:ok, view, _html} = live(build_conn(), "/catalog?min_price=12.50")

      assert has_element?(view, ~s(#catalog-price-form input[value="12.50"]))
      # A $12.50 floor keeps the $25, $30, and $120 products; only the $10
      # starter starts below it.
      assert product_hrefs(view) == ["ai-assistant", "physical-poster", "sold-out-digital"]
    end

    test "an unparseable price applies no bound instead of failing the page" do
      {:ok, view, _html} = live(build_conn(), "/catalog?min_price=banana")

      assert product_hrefs(view) == @all_products
      refute has_element?(view, "#filter-summary")
      assert has_element?(view, ~s(#catalog-price-form input[value="banana"]))
    end

    test "a negative price is ignored" do
      {:ok, view, _html} = live(build_conn(), "/catalog?min_price=-50")

      assert product_hrefs(view) == @all_products
      refute has_element?(view, "#filter-summary")
    end
  end

  describe "combined state" do
    test "clear filters restores everything at once" do
      {:ok, view, _html} =
        live(build_conn(), "/catalog?types=physical&stock=in&min_price=20")

      assert product_hrefs(view) == ["physical-poster"]

      view |> element("#clear-filters") |> render_click()

      assert_patch(view, "/catalog")
      assert product_hrefs(view) == @all_products
      refute has_element?(view, "#filter-summary")
      refute has_element?(view, "#clear-filters")
    end

    test "search and a type facet narrow together" do
      {:ok, view, _html} = live(build_conn(), "/catalog?q=digital")

      assert product_hrefs(view) == ["digital-starter", "sold-out-digital"]

      view |> element("#type-physical") |> render_click()

      assert has_element?(view, "h2", "Search results")
      assert product_hrefs(view) == []
    end

    test "a type facet counts against the other active filters" do
      {:ok, view, _html} = live(build_conn(), "/catalog?stock=in")

      # The sold-out digital is no longer countable, so Digital drops to one.
      assert chip_text(view, "#type-digital") =~ "1"
    end
  end

  describe "tampered input" do
    test "a types parameter outside the vocabulary is ignored" do
      {:ok, view, _html} = live(build_conn(), "/catalog?types=banana")

      assert product_hrefs(view) == @all_products
      refute has_element?(view, "#filter-summary")
    end

    test "a types parameter mixing junk with a real type selects only the real one" do
      {:ok, view, _html} = live(build_conn(), "/catalog?types=banana,digital")

      assert product_hrefs(view) == ["digital-starter", "sold-out-digital"]
    end

    test "a crafted chip payload does nothing" do
      {:ok, view, _html} = live(build_conn(), "/catalog")

      view |> element("#type-digital") |> render_click(%{"type" => "banana"})

      assert product_hrefs(view) == @all_products
      refute has_element?(view, "#filter-summary")
    end

    test "an unknown sort falls back to the default" do
      {:ok, view, _html} = live(build_conn(), "/catalog?sort=whatever")

      assert product_hrefs(view) == @all_products
      refute has_element?(view, "#filter-summary")
    end
  end
end
