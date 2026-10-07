defmodule CassWeb.CatalogPagesTest do
  use CassWeb.ConnCase

  import Cass.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Cass.Accounts.Scope
  alias Cass.Catalog

  # The products here are platform products, so publishing and archiving them
  # requires an admin scope. Public access itself is unchanged by ownership.
  setup do
    admin = admin_fixture()
    %{admin: admin, admin_scope: Scope.for_user(admin)}
  end

  describe "public catalog index" do
    setup %{admin_scope: admin_scope} do
      {:ok, category} =
        Catalog.create_category(%{name: "Digital Products", slug: "digital-products"})

      {:ok, child} =
        Catalog.create_child_category(category, %{name: "Templates", slug: "templates"})

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
      %{category: category, child: child, product: published}
    end

    test "GET /catalog lists categories and products", %{child: child, product: product} do
      {:ok, view, _html} = live(build_conn(), "/catalog")

      assert has_element?(view, "h1", "Catalog")
      assert has_element?(view, "h2", "Browse categories")
      assert has_element?(view, "a[href='/catalog/categories/digital-products']")
      assert has_element?(view, "#categories-grid")
      assert has_element?(view, "div", child.name)
      assert has_element?(view, "h2", "Latest additions")
      assert has_element?(view, "#products-grid")
      assert has_element?(view, "div", product.name)
      assert has_element?(view, "a[href='/catalog/products/sample-product']")
    end

    test "GET /catalog assigns SEO metadata" do
      {:ok, view, html} = live(build_conn(), "/catalog")

      assert html =~ "Catalog · CASS Marketplace"
      assert html =~ ~s(name="description")
      assert html =~ ~s(rel="canonical" href="#{CassWeb.Endpoint.url()}/catalog")
      assert has_element?(view, "h1", "Catalog")
    end
  end

  describe "catalog empty state" do
    test "GET /catalog shows the empty state without data" do
      {:ok, view, _html} = live(build_conn(), "/catalog")

      assert has_element?(view, "#categories-grid")
      assert has_element?(view, "#products-grid")
      assert has_element?(view, "div", "No categories published yet.")
      assert has_element?(view, "div", "No products published yet.")
    end
  end

  describe "public category page" do
    setup %{admin_scope: admin_scope} do
      {:ok, category} =
        Catalog.create_category(%{name: "Digital Products", slug: "digital-products"})

      {:ok, child} =
        Catalog.create_child_category(category, %{name: "Templates", slug: "templates"})

      {:ok, product} =
        Catalog.create_product(category, %{
          name: "Sample Product",
          slug: "sample-product",
          product_type: :digital,
          visibility: :public,
          short_description: "A short blurb."
        })

      {:ok, _} = Catalog.publish_product(admin_scope, product)
      %{category: category, child: child, product: product}
    end

    test "GET /catalog/categories/:slug renders the category page" do
      {:ok, view, html} = live(build_conn(), "/catalog/categories/digital-products")

      assert has_element?(view, "h1", "Digital Products")
      assert has_element?(view, "nav[aria-label=Breadcrumb]")
      assert has_element?(view, "nav[aria-label=Breadcrumb] a[href='/catalog']")
      assert has_element?(view, "a[href='/catalog/categories/templates']")
      assert has_element?(view, "h2", "Products in Digital Products")
      assert has_element?(view, "#category-products")
      assert has_element?(view, "h3", "Sample Product")
      assert has_element?(view, "a[href='/catalog/products/sample-product']")

      assert html =~
               ~s(rel="canonical" href="#{CassWeb.Endpoint.url()}/catalog/categories/digital-products")
    end

    test "GET /catalog/categories/:slug marks unknown categories noindex and renders not found" do
      {:ok, view, _html} = live(build_conn(), "/catalog/categories/somegone-slug")
      assert has_element?(view, "#not-found")
      refute has_element?(view, "h1", "Digital Products")
    end

    test "GET /catalog/categories/:slug returns not found for archived categories" do
      {:ok, category} = Catalog.create_category(%{name: "Gone", slug: "gone"})
      {:ok, _} = Catalog.archive_category(category)

      {:ok, view, _html} = live(build_conn(), "/catalog/categories/gone")
      assert has_element?(view, "#not-found")
    end
  end

  describe "public product page" do
    setup %{admin_scope: admin_scope} do
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
      %{category: category, product: published}
    end

    test "GET /catalog/products/:slug renders the product page" do
      {:ok, view, html} = live(build_conn(), "/catalog/products/sample-product")

      assert has_element?(view, "h1", "Sample Product")
      assert has_element?(view, "div", "A longer product description.")
      assert has_element?(view, "#product-details")
      assert has_element?(view, "dt", "Category")
      assert has_element?(view, "a[href='/catalog/categories/digital-products']")
      assert has_element?(view, "nav[aria-label=Breadcrumb]")
      assert html =~ ~s(name="description")
    end

    test "GET /catalog/products/:slug assigns the canonical URL" do
      {:ok, _view, html} = live(build_conn(), "/catalog/products/sample-product")

      assert html =~
               ~s(rel="canonical" href="#{CassWeb.Endpoint.url()}/catalog/products/sample-product")
    end

    test "GET /catalog/products/:slug returns not found for unknown, draft, private, and archived",
         %{admin_scope: admin_scope} do
      {:ok, category} = Catalog.create_category(%{name: "Hidden", slug: "hidden"})

      {:ok, draft} =
        Catalog.create_product(category, %{
          name: "Draft Item",
          slug: "draft-item",
          product_type: :ai,
          visibility: :public
        })

      {:ok, private} =
        Catalog.create_product(category, %{
          name: "Private Item",
          slug: "private-item",
          product_type: :ai,
          visibility: :private
        })

      {:ok, published_private} = Catalog.publish_product(admin_scope, private)

      {:ok, archived} =
        Catalog.create_product(category, %{
          name: "Archived Item",
          slug: "archived-item",
          product_type: :ai,
          visibility: :public
        })

      {:ok, published_archived} = Catalog.publish_product(admin_scope, archived)
      {:ok, archived_product} = Catalog.archive_product(admin_scope, published_archived)

      for slug <- ["draft-item", "private-item", "archived-item", "missing-item"] do
        {:ok, view, _html} = live(build_conn(), "/catalog/products/#{slug}")
        assert has_element?(view, "#not-found")
        refute has_element?(view, "h1", "Sample Product")
      end

      assert draft.status == :draft
      assert published_private.status == :published
      assert archived_product.status == :archived
    end

    test "GET /catalog/products/:slug returns not found for products in archived categories",
         %{admin_scope: admin_scope} do
      {:ok, category} = Catalog.create_category(%{name: "Soon Gone", slug: "soon-gone"})

      {:ok, product} =
        Catalog.create_product(category, %{
          name: "Doomed",
          slug: "doomed-product",
          product_type: :digital,
          visibility: :public
        })

      {:ok, _} = Catalog.publish_product(admin_scope, product)
      {:ok, _} = Catalog.archive_category(category)

      {:ok, view, _html} = live(build_conn(), "/catalog/products/doomed-product")
      assert has_element?(view, "#not-found")
    end

    test "GET /catalog/products/:slug serves unlisted products but marks them noindex",
         %{admin_scope: admin_scope} do
      {:ok, category} = Catalog.create_category(%{name: "Tools", slug: "tools"})

      {:ok, unlisted} =
        Catalog.create_product(category, %{
          name: "Unlisted Item",
          slug: "unlisted-item",
          product_type: :ai,
          visibility: :unlisted
        })

      {:ok, _} = Catalog.publish_product(admin_scope, unlisted)

      {:ok, view, html} = live(build_conn(), "/catalog/products/unlisted-item")
      assert has_element?(view, "h1", "Unlisted Item")
      assert html =~ ~s(name="robots" content="noindex, follow")
    end
  end

  describe "catalog search and sort" do
    setup %{admin_scope: admin_scope} do
      {:ok, category} = Catalog.create_category(%{name: "Media", slug: "media"})

      publish = fn name, slug, price ->
        {:ok, product} =
          Catalog.create_product(category, %{
            name: name,
            slug: slug,
            product_type: :digital,
            visibility: :public,
            short_description: "A #{name} listing."
          })

        {:ok, published} = Catalog.publish_product(admin_scope, product)

        {:ok, _variant} =
          Catalog.create_variant(admin_scope, published, %{
            name: "Standard",
            sku: "STD-#{slug}",
            price_cents: price,
            currency: "USD",
            stock: 5,
            active: true
          })

        published
      end

      vinyl = publish.("Vintage Vinyl", "vintage-vinyl", 5000)
      camera = publish.("Vintage Camera", "vintage-camera", 15_000)
      lens = publish.("Modern Lens", "modern-lens", 10_000)
      %{vinyl: vinyl, camera: camera, lens: lens}
    end

    defp product_hrefs(view) do
      view
      |> render()
      |> then(&Regex.scan(~r{href="/catalog/products/([a-z0-9-]+)"}, &1))
      |> Enum.map(fn [_, slug] -> slug end)
    end

    test "GET /catalog?q= filters products and shows the search summary", %{
      vinyl: vinyl,
      camera: camera
    } do
      {:ok, view, _html} = live(build_conn(), "/catalog?q=vintage")

      assert has_element?(view, "h2", "Search results")
      assert has_element?(view, "#search-summary")
      assert has_element?(view, "div", "Vintage Vinyl")
      assert has_element?(view, "div", "Vintage Camera")
      refute has_element?(view, "div", "Modern Lens")
      assert vinyl.status == :published
      assert camera.status == :published
    end

    test "GET /catalog?q= with no matches shows the dedicated empty state" do
      {:ok, view, _html} = live(build_conn(), "/catalog?q=zzz-no-match")

      assert has_element?(view, "h2", "Search results")
      assert has_element?(view, "div", "No products match your search")
      refute has_element?(view, "h2", "Latest additions")
    end

    test "submitting the search form refilters and updates the summary" do
      {:ok, view, _html} = live(build_conn(), "/catalog")

      assert has_element?(view, "h2", "Latest additions")

      view
      |> element("#catalog-search-form")
      |> render_submit(%{"q" => "camera"})

      assert has_element?(view, "h2", "Search results")
      assert has_element?(view, "div", "Vintage Camera")
      refute has_element?(view, "div", "Vintage Vinyl")
    end

    test "the sort select reorders products by lowest price" do
      {:ok, view, _html} = live(build_conn(), "/catalog")

      view
      |> element("#catalog-sort-form")
      |> render_change(%{"sort" => "price_asc"})

      assert product_hrefs(view) == ["vintage-vinyl", "modern-lens", "vintage-camera"]

      view
      |> element("#catalog-sort-form")
      |> render_change(%{"sort" => "price_desc"})

      assert product_hrefs(view) == ["vintage-camera", "modern-lens", "vintage-vinyl"]
    end

    test "clear search returns to the full catalog listing" do
      {:ok, view, _html} = live(build_conn(), "/catalog?q=vintage")

      assert has_element?(view, "#search-summary")

      view
      |> element("a[href='/catalog']#clear-search, #search-summary a")
      |> render_click()

      assert has_element?(view, "h2", "Latest additions")
      refute has_element?(view, "#search-summary")
    end
  end
end
