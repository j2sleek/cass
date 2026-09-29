defmodule CassWeb.ProductManagementLiveTest do
  @moduledoc """
  HTTP/LiveView boundary tests for the protected product management area.

  Two layers are under test: the route guard (guests are sent to log in, plain
  customers are refused) and the ownership resolution that every action performs
  with `Cass.Catalog.get_managed_product/2`. The injection tests deliberately
  bypass the `form/3` helper, because a real attacker sends whatever they like on
  the wire: only `render_submit/3` reproduces that.
  """
  use CassWeb.ConnCase

  import Cass.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Catalog.Product
  alias Cass.Repo

  setup do
    {:ok, category} = Catalog.create_category(%{name: "Digital", slug: "digital"})
    %{category: category}
  end

  defp signed_in(user), do: build_conn() |> log_in_user(user)

  defp form_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Seller Widget",
        "slug" => "seller-widget",
        "product_type" => "digital",
        "visibility" => "unlisted"
      },
      overrides
    )
  end

  # The edit form renders only these fields; the others are create-only.
  defp edit_params(overrides) do
    Map.merge(%{"name" => "Seller Widget", "visibility" => "unlisted"}, overrides)
  end

  defp product_attrs(overrides) do
    Map.merge(
      %{
        name: "Seller Widget",
        slug: "seller-widget",
        product_type: :digital,
        visibility: :unlisted
      },
      overrides
    )
  end

  defp create_owned!(scope, category, overrides \\ %{}) do
    {:ok, product} = Catalog.create_owned_product(scope, category, product_attrs(overrides))
    product
  end

  describe "route guard" do
    test "a guest is redirected to sign in", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/manage/products")
      assert path == ~p"/users/log-in"
    end

    test "a customer is refused" do
      customer = user_fixture()

      assert {:error, {:redirect, %{to: path, flash: flash}}} =
               customer |> signed_in() |> live(~p"/manage/products")

      assert path == ~p"/users/settings"
      assert flash["error"] =~ "not authorized"
    end

    test "a customer is refused on the new and edit routes too" do
      customer = user_fixture()

      for path <- [~p"/manage/products/new", ~p"/manage/products/1/edit"] do
        assert {:error, {:redirect, %{to: "/users/settings", flash: flash}}} =
                 customer |> signed_in() |> live(path)

        assert flash["error"] =~ "not authorized"
      end
    end

    test "a vendor sees the management area", %{category: category} do
      vendor = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)

      assert {:ok, view, _html} = live(vendor |> signed_in(), ~p"/manage/products")
      assert has_element?(view, "#manage-products")
      assert has_element?(view, "#product-#{product.id}")
    end

    test "an admin sees the management area" do
      assert {:ok, view, _html} =
               live(admin_fixture() |> signed_in(), ~p"/manage/products")

      assert has_element?(view, "#manage-products")
      assert has_element?(view, "#new-product-link")
    end
  end

  describe "management index" do
    setup %{category: category} do
      vendor = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)
      view = live(vendor |> signed_in(), ~p"/manage/products")
      {:ok, view, _html} = view

      %{view: view, vendor: vendor, product: product}
    end

    test "shows the seller's own products with their ownership", %{
      view: view,
      product: product
    } do
      assert has_element?(view, "#product-#{product.id}")
      assert has_element?(view, "#owner-#{product.id}", "Yours")
    end

    test "offers publish and archive actions and a create link", %{view: view, product: product} do
      assert has_element?(view, "#publish-product-#{product.id}")
      assert has_element?(view, "#archive-product-#{product.id}")
      assert has_element?(view, "#new-product-link")
    end

    test "a vendor does not see another seller's product", %{view: view, category: category} do
      other =
        create_owned!(Scope.for_user(vendor_fixture()), category, %{
          name: "Theirs",
          slug: "theirs"
        })

      refute has_element?(view, "#product-#{other.id}")
    end

    test "a vendor does not see platform products", %{view: view, category: category} do
      {:ok, platform} =
        Catalog.create_product(category, product_attrs(%{name: "Platform", slug: "platform"}))

      refute has_element?(view, "#product-#{platform.id}")
    end

    test "the owner can publish their own product", %{
      view: view,
      vendor: vendor,
      product: product
    } do
      view |> element("#publish-product-#{product.id}") |> render_submit()

      assert %{status: :published} =
               Catalog.get_managed_product(Scope.for_user(vendor), product.id)

      assert Catalog.get_public_product_by_slug("seller-widget")
      assert has_element?(view, "#product-#{product.id}")
    end

    test "the owner can archive their own product", %{
      view: view,
      vendor: vendor,
      product: product
    } do
      view |> element("#archive-product-#{product.id}") |> render_submit()

      assert %{status: :archived} =
               Catalog.get_managed_product(Scope.for_user(vendor), product.id)
    end

    test "a tampered product_id cannot publish somebody else's product", %{
      view: view,
      category: category
    } do
      victim =
        create_owned!(Scope.for_user(vendor_fixture()), category, %{
          name: "Victim",
          slug: "victim"
        })

      render_submit(view, "publish_product", %{"product_id" => victim.id})

      assert Repo.get!(Product, victim.id).status == :draft
    end

    test "a tampered product_id cannot archive somebody else's product", %{
      view: view,
      category: category
    } do
      victim =
        create_owned!(Scope.for_user(vendor_fixture()), category, %{
          name: "Victim",
          slug: "victim"
        })

      render_submit(view, "archive_product", %{"product_id" => victim.id})

      assert Repo.get!(Product, victim.id).status == :draft
    end

    test "an unknown or malformed product_id is simply not found", %{view: view} do
      render_submit(view, "publish_product", %{"product_id" => "999999"})
      render_submit(view, "archive_product", %{"product_id" => "not-a-number"})

      assert Repo.aggregate(Product, :count) == 1
    end
  end

  describe "admin index" do
    test "an admin sees every product, including platform and other sellers'", %{
      category: category
    } do
      vendor = vendor_fixture()

      vendor_product =
        create_owned!(Scope.for_user(vendor), category, %{name: "Theirs", slug: "theirs"})

      {:ok, platform} =
        Catalog.create_product(category, product_attrs(%{name: "Platform", slug: "platform"}))

      {:ok, view, _html} = live(admin_fixture() |> signed_in(), ~p"/manage/products")

      assert has_element?(view, "#product-#{vendor_product.id}")
      assert has_element?(view, "#owner-#{vendor_product.id}", "Seller")
      assert has_element?(view, "#product-#{platform.id}")
      assert has_element?(view, "#owner-#{platform.id}", "Platform")
    end
  end

  describe "create product" do
    setup %{category: category} do
      vendor = vendor_fixture()
      %{conn: signed_in(vendor), vendor: vendor, category: category}
    end

    test "renders the create form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/manage/products/new")

      assert has_element?(view, "#product-form")
      assert has_element?(view, "#save-product")
      assert has_element?(view, "#category_id")
    end

    test "creates a product owned by the signed-in vendor", %{
      conn: conn,
      vendor: vendor,
      category: category
    } do
      {:ok, view, _html} = live(conn, ~p"/manage/products/new")

      view
      |> form("#product-form", product: form_params())
      |> render_submit()

      assert [product] = Catalog.list_managed_products(Scope.for_user(vendor))
      assert product.owner_id == vendor.id
      assert product.status == :draft
      assert product.category_id == category.id
    end

    test "an owner_id submitted in the payload is ignored", %{
      conn: conn,
      vendor: vendor,
      category: category
    } do
      victim = vendor_fixture()
      {:ok, view, _html} = live(conn, ~p"/manage/products/new")

      render_submit(view, "save", %{
        "product" => form_params(%{"owner_id" => victim.id}),
        "category_id" => to_string(category.id)
      })

      assert [product] = Catalog.list_managed_products(Scope.for_user(vendor))
      assert product.owner_id == vendor.id
      refute product.owner_id == victim.id
    end

    test "an unknown category id creates nothing", %{conn: conn, vendor: vendor} do
      {:ok, view, _html} = live(conn, ~p"/manage/products/new")

      html =
        render_submit(view, "save", %{"product" => form_params(), "category_id" => "999999"})

      assert html =~ "please choose a category"
      assert Catalog.list_managed_products(Scope.for_user(vendor)) == []
    end

    test "a blank category creates nothing", %{conn: conn, vendor: vendor} do
      {:ok, view, _html} = live(conn, ~p"/manage/products/new")

      html = render_submit(view, "save", %{"product" => form_params(), "category_id" => ""})

      assert html =~ "please choose a category"
      assert Catalog.list_managed_products(Scope.for_user(vendor)) == []
    end

    test "validation errors are rendered and nothing is created", %{conn: conn, vendor: vendor} do
      {:ok, view, _html} = live(conn, ~p"/manage/products/new")

      html = render_submit(view, "save", %{"product" => form_params(%{"name" => ""})})

      assert html =~ "can&#39;t be blank"
      assert Catalog.list_managed_products(Scope.for_user(vendor)) == []
    end

    test "an admin creates a product owned by itself" do
      admin = admin_fixture()
      {:ok, view, _html} = live(signed_in(admin), ~p"/manage/products/new")

      view
      |> form("#product-form",
        product: form_params(%{"name" => "Admin Product", "slug" => "admin-product"})
      )
      |> render_submit()

      assert [product] = Catalog.list_managed_products(Scope.for_user(admin))
      assert product.owner_id == admin.id
    end
  end

  describe "edit product" do
    setup %{category: category} do
      vendor = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)
      %{conn: signed_in(vendor), vendor: vendor, product: product}
    end

    test "the owner sees their edit form", %{conn: conn, product: product} do
      {:ok, view, _html} = live(conn, ~p"/manage/products/#{product.id}/edit")

      assert has_element?(view, "#product-form")
      assert has_element?(view, "#product-id[value='#{product.id}']")
    end

    test "the owner can update their own product", %{
      conn: conn,
      vendor: vendor,
      product: product
    } do
      {:ok, view, _html} = live(conn, ~p"/manage/products/#{product.id}/edit")

      view
      |> form("#product-form", product: edit_params(%{"name" => "Renamed By Owner"}))
      |> render_submit()

      assert %{name: "Renamed By Owner"} =
               Catalog.get_managed_product(Scope.for_user(vendor), product.id)

      assert Repo.get!(Product, product.id).owner_id == vendor.id
    end

    test "an owner_id in the update payload cannot transfer ownership", %{
      conn: conn,
      vendor: vendor,
      product: product
    } do
      victim = vendor_fixture()
      {:ok, view, _html} = live(conn, ~p"/manage/products/#{product.id}/edit")

      render_submit(view, "update_product", %{
        "product" => edit_params(%{"name" => "Renamed", "owner_id" => victim.id}),
        "product_id" => to_string(product.id)
      })

      assert Repo.get!(Product, product.id).owner_id == vendor.id
      assert Repo.get!(Product, product.id).name == "Renamed"
    end

    test "another seller gets the same not-found page as a product that does not exist", %{
      product: product
    } do
      other = vendor_fixture()

      {:ok, own_view, _html} = other |> signed_in() |> live(~p"/manage/products")

      {:ok, foreign_view, foreign_html} =
        other |> signed_in() |> live(~p"/manage/products/#{product.id}/edit")

      # Probing somebody else's product is indistinguishable from probing a
      # product that was never created: no id, no name, no flash.
      assert has_element?(foreign_view, "#not-found")
      refute foreign_html =~ "Seller Widget"
      assert has_element?(own_view, "#manage-products")
    end

    test "a customer cannot reach the edit route at all", %{product: product} do
      assert {:error, {:redirect, %{to: path}}} =
               user_fixture() |> signed_in() |> live(~p"/manage/products/#{product.id}/edit")

      assert path == ~p"/users/settings"
    end

    test "a tampered product_id in an update event changes nothing", %{
      conn: conn,
      category: category,
      product: product
    } do
      victim =
        create_owned!(Scope.for_user(vendor_fixture()), category, %{
          name: "Victim",
          slug: "victim"
        })

      {:ok, view, _html} = live(conn, ~p"/manage/products/#{product.id}/edit")

      render_submit(view, "update_product", %{
        "product" => edit_params(%{"name" => "Hijacked"}),
        "product_id" => to_string(victim.id)
      })

      assert Repo.get!(Product, victim.id).name == "Victim"
      assert Repo.get!(Product, product.id).name == "Seller Widget"
    end

    test "an admin can edit another seller's product without changing its owner", %{
      product: product
    } do
      {:ok, view, _html} =
        live(admin_fixture() |> signed_in(), ~p"/manage/products/#{product.id}/edit")

      view
      |> form("#product-form", product: edit_params(%{"name" => "Edited By Admin"}))
      |> render_submit()

      assert Repo.get!(Product, product.id).name == "Edited By Admin"
      assert Repo.get!(Product, product.id).owner_id == product.owner_id
    end

    test "an unknown product id renders the not-found page", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/manage/products/999999/edit")

      assert has_element?(view, "#not-found")
      refute html =~ "product-form"
    end
  end

  describe "public pages never expose ownership" do
    setup %{category: category} do
      vendor = vendor_fixture()
      scope = Scope.for_user(vendor)
      product = create_owned!(scope, category, %{visibility: :public, slug: "public-widget"})
      {:ok, _} = Catalog.publish_product(scope, product)

      %{vendor: vendor, product: product}
    end

    test "the product page renders without owner data", %{conn: conn, vendor: vendor} do
      {:ok, _view, html} = live(conn, ~p"/catalog/products/public-widget")

      assert html =~ "Seller Widget"
      refute html =~ vendor.email
    end

    test "the public listing renders without owner data", %{conn: conn, vendor: vendor} do
      {:ok, _view, html} = live(conn, ~p"/catalog")

      assert html =~ "Seller Widget"
      refute html =~ vendor.email
    end

    test "the management area is not linked from a public page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/catalog")

      refute html =~ "/manage/products"
    end

    test "a customer is not offered the management link", %{category: category} do
      _ = category
      customer = user_fixture()

      {:ok, _view, html} = customer |> signed_in() |> live(~p"/catalog")

      refute html =~ "/manage/products"
    end

    test "a vendor is offered the management link", %{category: category} do
      _ = category

      {:ok, _view, html} = vendor_fixture() |> signed_in() |> live(~p"/catalog")

      assert html =~ "/manage/products"
    end
  end
end
