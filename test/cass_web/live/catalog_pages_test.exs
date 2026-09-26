defmodule CassWeb.CatalogPagesTest do
  use CassWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Cass.Catalog

  describe "public catalog index" do
    setup do
      {:ok, category} =
        Catalog.create_category(%{name: "Digital Products", slug: "digital-products"})

      {:ok, child} =
        Catalog.create_child_category(category, %{name: "Templates", slug: "templates"})

      {:ok, product} =
        Catalog.create_product(category, %{
          name: "Sample Product",
          slug: "sample-product",
          product_type: :digital_product,
          visibility: :public,
          short_description: "A short blurb.",
          description: "A longer product description."
        })

      {:ok, published} = Catalog.publish_product(product)
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
    setup do
      {:ok, category} =
        Catalog.create_category(%{name: "Digital Products", slug: "digital-products"})

      {:ok, child} =
        Catalog.create_child_category(category, %{name: "Templates", slug: "templates"})

      {:ok, product} =
        Catalog.create_product(category, %{
          name: "Sample Product",
          slug: "sample-product",
          product_type: :digital_product,
          visibility: :public,
          short_description: "A short blurb."
        })

      {:ok, _} = Catalog.publish_product(product)
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
    setup do
      {:ok, category} =
        Catalog.create_category(%{name: "Digital Products", slug: "digital-products"})

      {:ok, product} =
        Catalog.create_product(category, %{
          name: "Sample Product",
          slug: "sample-product",
          product_type: :digital_product,
          visibility: :public,
          short_description: "A short blurb.",
          description: "A longer product description."
        })

      {:ok, published} = Catalog.publish_product(product)
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

    test "GET /catalog/products/:slug returns not found for unknown, draft, private, and archived" do
      {:ok, category} = Catalog.create_category(%{name: "Hidden", slug: "hidden"})

      {:ok, draft} =
        Catalog.create_product(category, %{
          name: "Draft Item",
          slug: "draft-item",
          product_type: :ai_tool,
          visibility: :public
        })

      {:ok, private} =
        Catalog.create_product(category, %{
          name: "Private Item",
          slug: "private-item",
          product_type: :ai_tool,
          visibility: :private
        })

      {:ok, published_private} = Catalog.publish_product(private)

      {:ok, archived} =
        Catalog.create_product(category, %{
          name: "Archived Item",
          slug: "archived-item",
          product_type: :ai_tool,
          visibility: :public
        })

      {:ok, published_archived} = Catalog.publish_product(archived)
      {:ok, archived_product} = Catalog.archive_product(published_archived)

      for slug <- ["draft-item", "private-item", "archived-item", "missing-item"] do
        {:ok, view, _html} = live(build_conn(), "/catalog/products/#{slug}")
        assert has_element?(view, "#not-found")
        refute has_element?(view, "h1", "Sample Product")
      end

      assert draft.status == :draft
      assert published_private.status == :published
      assert archived_product.status == :archived
    end

    test "GET /catalog/products/:slug returns not found for products in archived categories" do
      {:ok, category} = Catalog.create_category(%{name: "Soon Gone", slug: "soon-gone"})

      {:ok, product} =
        Catalog.create_product(category, %{
          name: "Doomed",
          slug: "doomed-product",
          product_type: :digital_product,
          visibility: :public
        })

      {:ok, _} = Catalog.publish_product(product)
      {:ok, _} = Catalog.archive_category(category)

      {:ok, view, _html} = live(build_conn(), "/catalog/products/doomed-product")
      assert has_element?(view, "#not-found")
    end

    test "GET /catalog/products/:slug serves unlisted products but marks them noindex" do
      {:ok, category} = Catalog.create_category(%{name: "Tools", slug: "tools"})

      {:ok, unlisted} =
        Catalog.create_product(category, %{
          name: "Unlisted Item",
          slug: "unlisted-item",
          product_type: :ai_tool,
          visibility: :unlisted
        })

      {:ok, _} = Catalog.publish_product(unlisted)

      {:ok, view, html} = live(build_conn(), "/catalog/products/unlisted-item")
      assert has_element?(view, "h1", "Unlisted Item")
      assert html =~ ~s(name="robots" content="noindex, follow")
    end
  end
end
