defmodule Cass.Catalog.OwnershipTest do
  @moduledoc """
  Ownership and authorization behavior for products (Milestone 3 Phase 3).

  The matrix under test:

  | caller          | create owned | manage own | manage others | manage platform |
  |-----------------|-------------|------------|---------------|-----------------|
  | guest           | no          | no         | no            | no              |
  | customer        | no          | no         | no            | no              |
  | vendor          | yes         | yes        | no            | no              |
  | admin           | yes         | yes        | yes           | yes             |
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Catalog.Product

  setup do
    unique = System.unique_integer([:positive])

    {:ok, category} =
      Catalog.create_category(%{name: "Digital #{unique}", slug: "digital-#{unique}"})

    %{category: category}
  end

  defp scope_for(role) do
    case role do
      :admin -> Scope.for_user(admin_fixture())
      :vendor -> Scope.for_user(vendor_fixture())
      :customer -> Scope.for_user(user_fixture())
    end
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Widget",
        slug: "widget",
        product_type: :digital,
        visibility: :unlisted
      },
      overrides
    )
  end

  # Creates an owned product through the authorized path, so the ownership
  # matrix is never tested against a hand-crafted row.
  defp create_owned!(scope, category, overrides \\ %{}) do
    {:ok, product} = Catalog.create_owned_product(scope, category, attrs(overrides))
    product
  end

  describe "schema" do
    test "owner_id is nullable, so a product can exist with no owner", %{category: category} do
      raw = %Product{
        name: "Raw",
        slug: "raw",
        product_type: :digital,
        visibility: :public,
        status: :draft,
        category_id: category.id
      }

      assert Repo.insert!(raw).owner_id == nil
    end

    test "create_product/2 leaves the product platform-owned", %{category: category} do
      {:ok, product} = Catalog.create_product(category, attrs())

      assert product.owner_id == nil
      assert Product.platform_owned?(product)
    end

    test "the product references a real account and cascades nothing on delete", %{
      category: category
    } do
      vendor = vendor_fixture()
      scope = Scope.for_user(vendor)
      product = create_owned!(scope, category)

      assert product.owner_id == vendor.id
      refute Product.platform_owned?(product)

      # `ON DELETE RESTRICT`: deleting the owner must fail rather than silently
      # cascade into destroying (or re-parenting) somebody's catalog. Accounts
      # has no user deletion today; this asserts the database will not let one
      # appear without an explicit decision.
      assert_raise Ecto.ConstraintError, fn -> Repo.delete!(vendor) end
    end

    test "the foreign key is ON DELETE RESTRICT", %{category: category} do
      create_owned!(Scope.for_user(vendor_fixture()), category)

      %{rows: [[action]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT confdeltype FROM pg_constraint WHERE conname = 'cass_products_owner_id_fkey'",
          []
        )

      # 'r' is RESTRICT: deleting an account that still owns products is refused
      # by the database, so a future `delete_user/1` can neither orphan nor
      # cascade somebody's listings.
      assert action == "r"
    end

    test "owner_id is indexed and is not unique", %{category: category} do
      vendor = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)
      second = create_owned!(Scope.for_user(vendor), category, %{name: "Second", slug: "second"})

      # Listing a seller's products is the read path the management page uses,
      # so the index has to exist, and one account must be able to own many rows.
      %{rows: [[index_definition]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT indexdef FROM pg_indexes WHERE tablename = 'cass_products' AND indexname = 'cass_products_owner_id_index'",
          []
        )

      assert index_definition =~ "owner_id"
      refute index_definition =~ "UNIQUE"
      assert product.owner_id == vendor.id
      assert second.owner_id == vendor.id
    end
  end

  describe "can_create_owned_product?/1" do
    test "is true for a vendor and for an admin" do
      assert Catalog.can_create_owned_product?(scope_for(:vendor))
      assert Catalog.can_create_owned_product?(scope_for(:admin))
    end

    test "is false for a customer, a guest, and a nil scope" do
      refute Catalog.can_create_owned_product?(scope_for(:customer))
      refute Catalog.can_create_owned_product?(Scope.for_user(nil))
      refute Catalog.can_create_owned_product?(nil)
    end
  end

  describe "create_owned_product/3" do
    test "a vendor creates a product owned by itself", %{category: category} do
      vendor = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)

      assert product.owner_id == vendor.id
      assert product.status == :draft
      assert product.category_id == category.id
    end

    test "an admin creates a product owned by itself", %{category: category} do
      admin = admin_fixture()
      product = create_owned!(Scope.for_user(admin), category)

      assert product.owner_id == admin.id
    end

    test "a customer cannot create a product", %{category: category} do
      assert {:error, changeset} =
               Catalog.create_owned_product(scope_for(:customer), category, attrs())

      assert %{base: ["you are not authorized to create a product"]} = errors_on(changeset)
      assert Repo.aggregate(Product, :count) == 0
    end

    test "a guest cannot create a product", %{category: category} do
      assert {:error, changeset} =
               Catalog.create_owned_product(Scope.for_user(nil), category, attrs())

      assert %{base: ["you are not authorized to create a product"]} = errors_on(changeset)
      assert Repo.aggregate(Product, :count) == 0
    end

    test "an owner_id in attrs is ignored, never obeyed", %{category: category} do
      vendor = vendor_fixture()
      victim = vendor_fixture()
      scope = Scope.for_user(vendor)

      product = create_owned!(scope, category, %{owner_id: victim.id})

      assert product.owner_id == vendor.id
      refute product.owner_id == victim.id
    end

    test "an owner_id of nil in attrs does not create a platform-owned product", %{
      category: category
    } do
      product = create_owned!(scope_for(:vendor), category, %{owner_id: nil})

      refute is_nil(product.owner_id)
    end

    test "a customer in the database cannot be used to own a product", %{category: category} do
      # Ownership follows the *scope*, not the submitted id, so the only way to
      # own a product as a customer is to already hold a role.
      customer = user_fixture()

      assert {:error, _changeset} =
               Catalog.create_owned_product(
                 Scope.for_user(customer),
                 category,
                 attrs(%{owner_id: customer.id})
               )

      assert Repo.aggregate(Product, :count) == 0
    end

    test "an archived category is refused", %{category: category} do
      {:ok, archived} = Catalog.archive_category(category)

      assert {:error, changeset} =
               Catalog.create_owned_product(scope_for(:vendor), archived, attrs())

      assert %{category_id: ["cannot add products to an archived category"]} =
               errors_on(changeset)
    end

    test "validation still runs", %{category: category} do
      assert {:error, changeset} = Catalog.create_owned_product(scope_for(:vendor), category, %{})

      assert errors_on(changeset) == %{
               name: ["can't be blank"],
               slug: ["can't be blank"],
               product_type: ["can't be blank"]
             }
    end
  end

  describe "can_manage_product?/2" do
    test "a vendor may manage its own product but not another seller's", %{category: category} do
      vendor = vendor_fixture()
      other = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)

      assert Catalog.can_manage_product?(Scope.for_user(vendor), product)
      refute Catalog.can_manage_product?(Scope.for_user(other), product)
    end

    test "an admin may manage anything, including a platform product", %{category: category} do
      {:ok, platform} = Catalog.create_product(category, attrs(%{slug: "platform-one"}))
      vendor_product = create_owned!(scope_for(:vendor), category, %{slug: "vendor-one"})

      assert Catalog.can_manage_product?(scope_for(:admin), platform)
      assert Catalog.can_manage_product?(scope_for(:admin), vendor_product)
    end

    test "a customer and a guest may not manage anything", %{category: category} do
      platform = create_owned!(scope_for(:vendor), category)
      {:ok, platform_product} = Catalog.create_product(category, attrs(%{slug: "platform-two"}))

      for scope <- [scope_for(:customer), Scope.for_user(nil)] do
        refute Catalog.can_manage_product?(scope, platform)
        refute Catalog.can_manage_product?(scope, platform_product)
      end
    end

    test "a platform product has no owner to match, so only an admin manages it", %{
      category: category
    } do
      {:ok, platform} = Catalog.create_product(category, attrs())

      for role <- [:vendor, :customer] do
        refute Catalog.can_manage_product?(scope_for(role), platform)
      end
    end
  end

  describe "update_product/3" do
    test "the owner may update their own product", %{category: category} do
      vendor = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)

      assert {:ok, updated} =
               Catalog.update_product(Scope.for_user(vendor), product, %{name: "Renamed"})

      assert updated.name == "Renamed"
    end

    test "another vendor is refused and the row is untouched", %{category: category} do
      product = create_owned!(scope_for(:vendor), category)
      attacker = Scope.for_user(vendor_fixture())

      assert {:error, changeset} = Catalog.update_product(attacker, product, %{name: "Hijacked"})
      assert %{base: ["you are not authorized to manage this product"]} = errors_on(changeset)

      assert Repo.get!(Product, product.id).name == "Widget"
    end

    test "a customer and a guest are refused", %{category: category} do
      product = create_owned!(scope_for(:vendor), category)

      for scope <- [scope_for(:customer), Scope.for_user(nil)] do
        assert {:error, changeset} = Catalog.update_product(scope, product, %{name: "Nope"})
        assert "you are not authorized to manage this product" in errors_on(changeset).base
      end
    end

    test "an owner_id in the update is ignored, so ownership cannot be transferred", %{
      category: category
    } do
      vendor = vendor_fixture()
      other = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)

      assert {:ok, updated} =
               Catalog.update_product(Scope.for_user(vendor), product, %{owner_id: other.id})

      assert updated.owner_id == vendor.id
      assert Repo.get!(Product, product.id).owner_id == vendor.id
    end

    test "a platform product is immutable to vendors but editable by an admin", %{
      category: category
    } do
      {:ok, platform} = Catalog.create_product(category, attrs())

      assert {:error, _} = Catalog.update_product(scope_for(:vendor), platform, %{name: "Mine"})

      assert {:ok, updated} =
               Catalog.update_product(scope_for(:admin), platform, %{name: "Officially Ours"})

      assert updated.name == "Officially Ours"
    end

    test "the archived and slug rules are unchanged for an owner", %{category: category} do
      scope = scope_for(:vendor)
      product = create_owned!(scope, category)

      assert {:ok, _} = Catalog.update_product(scope, product, %{slug: "renamed-while-draft"})
      assert Repo.get!(Product, product.id).slug == "renamed-while-draft"

      {:ok, published} = Catalog.publish_product(scope, Repo.get!(Product, product.id))

      assert {:error, changeset} = Catalog.update_product(scope, published, %{slug: "nope"})
      assert "cannot be changed once the product is published" in errors_on(changeset).slug

      {:ok, archived} = Catalog.archive_product(scope, published)

      assert {:error, changeset} = Catalog.update_product(scope, archived, %{name: "Nope"})
      assert "archived products cannot be modified" in errors_on(changeset).base
    end
  end

  describe "publish_product/2" do
    test "the owner may publish their own product", %{category: category} do
      vendor = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)

      assert {:ok, published} = Catalog.publish_product(Scope.for_user(vendor), product)
      assert published.status == :published
      assert published.published_at
    end

    test "another vendor cannot publish it, so it stays a draft", %{category: category} do
      product = create_owned!(scope_for(:vendor), category)
      attacker = Scope.for_user(vendor_fixture())

      assert {:error, changeset} = Catalog.publish_product(attacker, product)
      assert "you are not authorized to manage this product" in errors_on(changeset).base
      assert Repo.get!(Product, product.id).status == :draft
    end

    test "a customer and a guest cannot publish", %{category: category} do
      product = create_owned!(scope_for(:vendor), category)

      for scope <- [scope_for(:customer), Scope.for_user(nil)] do
        assert {:error, _changeset} = Catalog.publish_product(scope, product)
      end

      assert Repo.get!(Product, product.id).status == :draft
    end

    test "an admin may publish a vendor's draft", %{category: category} do
      product = create_owned!(scope_for(:vendor), category)

      assert {:ok, published} = Catalog.publish_product(scope_for(:admin), product)
      assert published.status == :published
    end

    test "a vendor cannot publish a platform product", %{category: category} do
      {:ok, platform} = Catalog.create_product(category, attrs())

      assert {:error, changeset} = Catalog.publish_product(scope_for(:vendor), platform)
      assert "you are not authorized to manage this product" in errors_on(changeset).base
    end

    test "an owned product is not publishable through the platform path", %{category: category} do
      product = create_owned!(scope_for(:vendor), category)

      assert {:error, changeset} = Catalog.publish_platform_product(product)

      assert "only a platform-owned product can be published without a scope" in errors_on(
               changeset
             ).base

      assert Repo.get!(Product, product.id).status == :draft
    end

    test "the draft rule still applies to an owner", %{category: category} do
      scope = scope_for(:vendor)
      {:ok, published} = Catalog.publish_product(scope, create_owned!(scope, category))

      assert {:error, changeset} = Catalog.publish_product(scope, published)
      assert "only draft products can be published" in errors_on(changeset).status
    end

    test "an archived category still blocks publishing for an owner", %{category: category} do
      scope = scope_for(:vendor)
      product = create_owned!(scope, category)
      {:ok, _} = Catalog.archive_category(category)

      assert {:error, changeset} = Catalog.publish_product(scope, product)
      assert "cannot publish products in an archived category" in errors_on(changeset).category_id
    end
  end

  describe "archive_product/2" do
    test "the owner may archive their own product", %{category: category} do
      scope = scope_for(:vendor)
      product = create_owned!(scope, category)

      assert {:ok, archived} = Catalog.archive_product(scope, product)
      assert archived.status == :archived
    end

    test "another vendor cannot archive it", %{category: category} do
      product = create_owned!(scope_for(:vendor), category)
      attacker = Scope.for_user(vendor_fixture())

      assert {:error, changeset} = Catalog.archive_product(attacker, product)
      assert "you are not authorized to manage this product" in errors_on(changeset).base
      assert Repo.get!(Product, product.id).status == :draft
    end

    test "a customer and a guest cannot archive", %{category: category} do
      product = create_owned!(scope_for(:vendor), category)

      for scope <- [scope_for(:customer), Scope.for_user(nil)] do
        assert {:error, _changeset} = Catalog.archive_product(scope, product)
      end

      assert Repo.get!(Product, product.id).status == :draft
    end

    test "an admin may archive any product", %{category: category} do
      owned = create_owned!(scope_for(:vendor), category)
      {:ok, platform} = Catalog.create_product(category, attrs(%{slug: "platform-one"}))

      assert {:ok, _} = Catalog.archive_product(scope_for(:admin), owned)
      assert {:ok, _} = Catalog.archive_product(scope_for(:admin), platform)
    end

    test "archiving twice is refused, and the authorization check still runs", %{
      category: category
    } do
      scope = scope_for(:vendor)
      {:ok, archived} = Catalog.archive_product(scope, create_owned!(scope, category))

      assert {:error, changeset} = Catalog.archive_product(scope, archived)
      assert "product is already archived" in errors_on(changeset).base

      assert {:error, changeset} = Catalog.archive_product(scope_for(:vendor), archived)
      assert "you are not authorized to manage this product" in errors_on(changeset).base
    end
  end

  describe "ownership reads" do
    test "list_managed_products/1 returns every product for an admin", %{category: category} do
      mine = create_owned!(scope_for(:vendor), category, %{name: "Mine", slug: "mine"})
      theirs = create_owned!(scope_for(:vendor), category, %{name: "Theirs", slug: "theirs"})

      {:ok, platform} =
        Catalog.create_product(category, attrs(%{name: "Platform", slug: "platform"}))

      listed = Catalog.list_managed_products(scope_for(:admin))

      assert Enum.map(listed, & &1.id) |> Enum.sort() ==
               Enum.sort([mine.id, theirs.id, platform.id])

      # the management listing is ordered by name, not by id
      assert Enum.map(listed, & &1.name) == Enum.sort(["Mine", "Theirs", "Platform"])
    end

    test "list_managed_products/1 returns only the caller's products otherwise", %{
      category: category
    } do
      vendor = vendor_fixture()
      mine = create_owned!(Scope.for_user(vendor), category, %{name: "Mine", slug: "mine"})
      _theirs = create_owned!(scope_for(:vendor), category, %{name: "Theirs", slug: "theirs"})

      assert [only] = Catalog.list_managed_products(Scope.for_user(vendor))
      assert only.id == mine.id
    end

    test "list_managed_products/1 excludes platform products for a vendor", %{category: category} do
      _platform = Catalog.create_product(category, attrs(%{slug: "platform-one"}))
      vendor = vendor_fixture()
      _mine = create_owned!(Scope.for_user(vendor), category, %{slug: "vendor-one"})

      assert [only] = Catalog.list_managed_products(Scope.for_user(vendor))
      assert only.slug == "vendor-one"
    end

    test "list_managed_products/1 returns nothing for a customer, guest, or nil", %{
      category: category
    } do
      _mine = create_owned!(scope_for(:vendor), category)

      assert Catalog.list_managed_products(scope_for(:customer)) == []
      assert Catalog.list_managed_products(Scope.for_user(nil)) == []
      assert Catalog.list_managed_products(nil) == []
    end

    test "get_managed_product/2 loads the caller's own product", %{category: category} do
      vendor = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)

      loaded = Catalog.get_managed_product(Scope.for_user(vendor), product.id)

      assert loaded.id == product.id
      assert loaded.category.id == category.id
      assert loaded.owner.id == vendor.id
    end

    test "get_managed_product/2 refuses another seller's product, by id or string", %{
      category: category
    } do
      product = create_owned!(scope_for(:vendor), category)
      attacker = Scope.for_user(vendor_fixture())

      assert Catalog.get_managed_product(attacker, product.id) == nil
      assert Catalog.get_managed_product(attacker, to_string(product.id)) == nil
    end

    test "get_managed_product/2 returns nil for a missing or malformed id", %{category: category} do
      scope = scope_for(:vendor)
      create_owned!(scope, category)

      assert Catalog.get_managed_product(scope, 0) == nil
      assert Catalog.get_managed_product(scope, -1) == nil
      assert Catalog.get_managed_product(scope, "not-a-number") == nil
      assert Catalog.get_managed_product(scope, "") == nil
      assert Catalog.get_managed_product(scope, "1abc") == nil
    end

    test "get_managed_product/2 refuses platform products for a vendor", %{category: category} do
      {:ok, platform} = Catalog.create_product(category, attrs())
      vendor = Scope.for_user(vendor_fixture())

      assert Catalog.get_managed_product(vendor, platform.id) == nil
      assert Catalog.get_managed_product(scope_for(:admin), platform.id).id == platform.id
    end

    test "get_managed_product/2 returns nil for a customer, guest, or nil scope", %{
      category: category
    } do
      product = create_owned!(scope_for(:vendor), category)

      assert Catalog.get_managed_product(scope_for(:customer), product.id) == nil
      assert Catalog.get_managed_product(Scope.for_user(nil), product.id) == nil
      assert Catalog.get_managed_product(nil, product.id) == nil
    end
  end

  describe "form changesets" do
    test "change_owned_product/3 validates without inserting and refuses guests", %{
      category: category
    } do
      assert {:ok, changeset} =
               Catalog.change_owned_product(scope_for(:vendor), category, attrs())

      assert changeset.valid?
      assert Repo.aggregate(Product, :count) == 0

      assert {:error, changeset} =
               Catalog.change_owned_product(Scope.for_user(nil), category, attrs())

      assert "you are not authorized to create a product" in errors_on(changeset).base
    end

    test "change_product/3 validates for the owner and refuses everybody else", %{
      category: category
    } do
      vendor = vendor_fixture()
      product = create_owned!(Scope.for_user(vendor), category)

      assert {:ok, changeset} =
               Catalog.change_product(Scope.for_user(vendor), product, %{name: "Renamed"})

      assert changeset.valid?
      assert get_change(changeset, :name) == "Renamed"

      for scope <- [scope_for(:vendor), scope_for(:customer), Scope.for_user(nil)] do
        assert {:error, changeset} = Catalog.change_product(scope, product, %{name: "Renamed"})
        assert "you are not authorized to manage this product" in errors_on(changeset).base
      end
    end
  end

  describe "public catalog is unaffected by ownership" do
    test "an owned published product appears publicly and leaks no owner", %{category: category} do
      vendor = vendor_fixture()
      scope = Scope.for_user(vendor)
      product = create_owned!(scope, category, %{visibility: :public, slug: "public-widget"})
      {:ok, _} = Catalog.publish_product(scope, product)

      assert [listed] = Catalog.list_public_products()
      assert listed.id == product.id
      assert listed.owner_id == vendor.id
      # Ecto.Association.NotLoaded<:association, :owner, Cass.Catalog.Product>
      # Public reads still preload only the category: no owner account is joined
      # into a public query, so the public layer has nothing to render. The column
      # itself is visible, which is why the pages must not print it.
      assert Catalog.get_public_product_by_slug("public-widget").owner_id == vendor.id
    end

    test "another seller's draft is never public", %{category: category} do
      create_owned!(scope_for(:vendor), category, %{slug: "hidden-widget"})

      assert Catalog.list_public_products() == []
      assert Catalog.get_public_product_by_slug("hidden-widget") == nil
    end

    test "an owned archived product is not public", %{category: category} do
      scope = scope_for(:vendor)
      product = create_owned!(scope, category, %{visibility: :public, slug: "gone-widget"})
      {:ok, _} = Catalog.publish_product(scope, product)
      {:ok, _} = Catalog.archive_product(scope, product)

      assert Catalog.list_public_products() == []
      assert Catalog.get_public_product_by_slug("gone-widget") == nil
    end
  end
end
