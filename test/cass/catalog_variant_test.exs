defmodule Cass.Catalog.VariantTest do
  @moduledoc """
  Product variant behavior: pricing, configuration, lifecycle, and the
  scope-first authorization model inherited from the parent product.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Catalog.ProductVariant

  setup do
    {:ok, category} = Catalog.create_category(%{name: "Digital", slug: "digital"})
    %{category: category}
  end

  defp scope_for(:admin), do: Scope.for_user(admin_fixture())
  defp scope_for(:vendor), do: Scope.for_user(vendor_fixture())
  defp scope_for(:customer), do: Scope.for_user(user_fixture())
  defp scope_for(:guest), do: Scope.for_user(nil)

  defp product_attrs do
    %{name: "TikTok Followers", slug: "tiktok-followers", product_type: :smm, visibility: :public}
  end

  defp owned_product!(scope, category, overrides \\ %{}) do
    {:ok, product} =
      Catalog.create_owned_product(scope, category, Map.merge(product_attrs(), overrides))

    product
  end

  defp platform_product!(category) do
    {:ok, product} =
      Catalog.create_product(
        category,
        Map.put(product_attrs(), :slug, "platform-followers")
      )

    product
  end

  defp variant_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "1,000",
        sku: "TIK-#{System.unique_integer([:positive])}",
        price_cents: 499,
        currency: "USD",
        stock: 100,
        sort_order: 1,
        config: %{"platform" => "tiktok", "target_type" => "followers"}
      },
      overrides
    )
  end

  describe "variants belong to exactly one product" do
    test "a product has many variants and every variant names its product", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      {:ok, small} = Catalog.create_variant(owner, product, variant_attrs(%{name: "1,000"}))
      {:ok, large} = Catalog.create_variant(owner, product, variant_attrs(%{name: "10,000"}))

      assert small.product_id == product.id
      assert large.product_id == product.id

      loaded = Cass.Repo.preload(product, :variants)

      assert Enum.map(loaded.variants, & &1.id) |> Enum.sort() ==
               Enum.sort([small.id, large.id])

      assert Cass.Repo.get!(ProductVariant, small.id).product_id == product.id
    end

    test "the database refuses a variant whose product does not exist" do
      changeset =
        %ProductVariant{}
        |> ProductVariant.changeset(variant_attrs())
        |> Ecto.Changeset.put_change(:product_id, 99_999_999)

      assert {:error, changeset} = Cass.Repo.insert(changeset)

      assert {:product, {"does not exist", opts}} =
               List.keyfind(changeset.errors, :product, 0)

      assert is_list(opts)
    end
  end

  describe "pricing and configuration" do
    test "pricing is stored in integer minor units with a currency", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      {:ok, variant} =
        Catalog.create_variant(owner, product, variant_attrs(%{price_cents: 199_99}))

      assert variant.price_cents == 199_99
      assert variant.currency == "USD"
      assert variant.stock == 100
      assert variant.active == true
    end

    test "variant configuration is stored and read back as a map", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      config = %{
        "platform" => "tiktok",
        "min_quantity" => 100,
        "max_quantity" => 50_000,
        "refill_supported" => true
      }

      {:ok, variant} = Catalog.create_variant(owner, product, variant_attrs(%{config: config}))
      assert Cass.Repo.get!(ProductVariant, variant.id).config == config
    end

    test "variant configuration must use string keys", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      assert {:error, changeset} =
               Catalog.create_variant(
                 owner,
                 product,
                 variant_attrs(%{config: %{platform: "tiktok"}})
               )

      assert "must use string keys" in errors_on(changeset).config
    end
  end

  describe "validation" do
    test "a name is required", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      assert {:error, changeset} =
               Catalog.create_variant(owner, product, Map.drop(variant_attrs(), [:name]))

      assert errors_on(changeset) == %{name: ["can't be blank"]}
    end

    test "prices and stock cannot be negative", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      for overrides <- [%{price_cents: -1}, %{stock: -1}] do
        assert {:error, changeset} =
                 Catalog.create_variant(owner, product, variant_attrs(overrides))

        field = if overrides[:price_cents], do: :price_cents, else: :stock
        assert "must be greater than or equal to 0" in errors_on(changeset)[field]
      end
    end

    test "variant names are unique within a product", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      assert {:ok, _} = Catalog.create_variant(owner, product, variant_attrs(%{name: "1,000"}))
      assert {:ok, _} = Catalog.create_variant(owner, product, variant_attrs(%{name: "10,000"}))

      assert {:error, changeset} =
               Catalog.create_variant(owner, product, variant_attrs(%{name: "1,000"}))

      assert "has already been taken" in errors_on(changeset).name
    end

    test "the same variant name is allowed on a different product", %{category: category} do
      owner = scope_for(:vendor)
      other = owned_product!(owner, category, %{slug: "other-product"})

      assert {:ok, _} =
               Catalog.create_variant(owner, other, variant_attrs(%{name: "1,000"}))
    end

    test "SKUs are globally unique", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      assert {:ok, _} = Catalog.create_variant(owner, product, variant_attrs(%{sku: "TIK-FIXED"}))

      assert {:error, changeset} =
               Catalog.create_variant(
                 owner,
                 product,
                 variant_attrs(%{name: "x", sku: "TIK-FIXED"})
               )

      assert "has already been taken" in errors_on(changeset).sku
    end
  end

  describe "active and purchasable variants" do
    test "only active variants are listed as purchasable", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      {:ok, active} = Catalog.create_variant(owner, product, variant_attrs(%{name: "A"}))
      {:ok, inactive} = Catalog.create_variant(owner, product, variant_attrs(%{name: "B"}))

      {:ok, inactive} = Catalog.update_variant(owner, inactive, %{active: false})

      assert ProductVariant.purchasable?(active) == true
      assert ProductVariant.purchasable?(inactive) == false
      assert [returned] = Catalog.list_active_variants(product)
      assert returned.id == active.id
    end

    test "an inactive variant cannot be purchased", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      {:ok, inactive} = Catalog.create_variant(owner, product, variant_attrs())
      {:ok, inactive} = Catalog.update_variant(owner, inactive, %{active: false})

      refute ProductVariant.purchasable?(inactive)
    end

    test "variants are ordered by sort_order then id", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      {:ok, _first} =
        Catalog.create_variant(owner, product, variant_attrs(%{name: "A", sort_order: 2}))

      {:ok, _second} =
        Catalog.create_variant(owner, product, variant_attrs(%{name: "B", sort_order: 1}))

      assert Enum.map(Catalog.list_active_variants(product), & &1.name) == ["B", "A"]
    end
  end

  describe "variant authorization" do
    test "the owner may create, update, and list variants", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      {:ok, variant} = Catalog.create_variant(owner, product, variant_attrs())
      {:ok, updated} = Catalog.update_variant(owner, variant, %{price_cents: 999})
      assert updated.price_cents == 999
      assert [listed] = Catalog.list_product_variants(owner, product)
      assert listed.product_id == updated.product_id
      assert listed.price_cents == 999
    end

    test "another vendor cannot touch another seller's product", %{category: category} do
      owner = scope_for(:vendor)
      intruder = scope_for(:vendor)
      product = owned_product!(owner, category)

      assert {:error, changeset} =
               Catalog.create_variant(intruder, product, variant_attrs())

      assert "you are not authorized to manage this product" in errors_on(changeset).base
      assert Catalog.list_product_variants(intruder, product) == []

      # Nothing was written by the refused create.
      assert Catalog.list_active_variants(product) == []
    end

    test "a vendor cannot add variants to a platform-owned product", %{category: category} do
      vendor = scope_for(:vendor)
      product = platform_product!(category)

      assert {:error, changeset} = Catalog.create_variant(vendor, product, variant_attrs())
      assert "you are not authorized to manage this product" in errors_on(changeset).base
    end

    test "a customer and a guest are refused", %{category: category} do
      owner = scope_for(:vendor)
      product = owned_product!(owner, category)

      for caller <- [scope_for(:customer), scope_for(:guest)] do
        assert {:error, changeset} = Catalog.create_variant(caller, product, variant_attrs())
        assert "you are not authorized to manage this product" in errors_on(changeset).base
        assert Catalog.list_product_variants(caller, product) == []
      end
    end

    test "an admin manages any product's variants", %{category: category} do
      admin = scope_for(:admin)
      vendor = scope_for(:vendor)
      owned = owned_product!(vendor, category)
      platform = platform_product!(category)

      {:ok, owned_variant} = Catalog.create_variant(admin, owned, variant_attrs())
      {:ok, platform_variant} = Catalog.create_variant(admin, platform, variant_attrs())

      assert owned_variant.product_id == owned.id
      assert platform_variant.product_id == platform.id

      assert [owned_listed] = Catalog.list_product_variants(admin, owned)
      assert owned_listed.id == owned_variant.id

      assert [platform_listed] = Catalog.list_product_variants(admin, platform)
      assert platform_listed.id == platform_variant.id
    end

    test "a product_id in attrs is ignored, never obeyed", %{category: category} do
      owner = scope_for(:vendor)
      mine = owned_product!(owner, category)
      other = owned_product!(owner, category, %{slug: "other-product"})

      {:ok, variant} =
        Catalog.create_variant(owner, mine, variant_attrs(%{product_id: other.id}))

      assert variant.product_id == mine.id
    end

    test "the variant changeset form path validates and refuses outsiders", %{category: category} do
      owner = scope_for(:vendor)
      intruder = scope_for(:vendor)
      product = owned_product!(owner, category)

      assert {:ok, changeset} = Catalog.change_variant(owner, product, variant_attrs())
      assert changeset.valid?

      assert {:error, changeset} = Catalog.change_variant(intruder, product, variant_attrs())
      assert "you are not authorized to manage this product" in errors_on(changeset).base
    end
  end
end
