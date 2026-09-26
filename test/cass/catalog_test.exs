defmodule Cass.CatalogTest do
  use Cass.DataCase, async: true

  alias Cass.Catalog

  describe "categories" do
    test "create_category/1 creates an active root category" do
      assert {:ok, category} =
               Catalog.create_category(%{name: "Digital Products", slug: "digital-products"})

      assert category.parent_id == nil
      assert category.status == :active
    end

    test "create_category/1 requires a name and slug" do
      assert {:error, changeset} = Catalog.create_category(%{})
      assert errors_on(changeset) == %{name: ["can't be blank"], slug: ["can't be blank"]}
    end

    test "create_category/1 rejects malformed slugs" do
      for slug <- ["Bad Slug", "UPPERCASE", "double--hyphen", "trailing-", "under_score"] do
        assert {:error, changeset} = Catalog.create_category(%{name: "A", slug: slug})

        assert "must be lowercase letters, numbers, and single hyphens" in errors_on(changeset).slug
      end
    end

    test "create_category/1 rejects duplicate slugs" do
      assert {:ok, _} = Catalog.create_category(%{name: "Digital", slug: "digital"})
      assert {:error, changeset} = Catalog.create_category(%{name: "Digital 2", slug: "digital"})
      assert "has already been taken" in errors_on(changeset).slug
    end

    test "category names are unique among siblings, case-insensitively" do
      assert {:ok, parent} = Catalog.create_category(%{name: "Tools", slug: "tools"})

      assert {:ok, _} =
               Catalog.create_child_category(parent, %{name: "Web Tools", slug: "web-tools"})

      assert {:error, changeset} =
               Catalog.create_child_category(parent, %{name: "web tools", slug: "web-tools-2"})

      assert "has already been taken" in errors_on(changeset).name
    end

    test "same category name is allowed at different parents and roots" do
      assert {:ok, parent_a} = Catalog.create_category(%{name: "Alpha", slug: "alpha"})
      assert {:ok, parent_b} = Catalog.create_category(%{name: "Beta", slug: "beta"})

      assert {:ok, _} =
               Catalog.create_child_category(parent_a, %{name: "Services", slug: "a-svc"})

      assert {:ok, _} =
               Catalog.create_child_category(parent_b, %{name: "Services", slug: "b-svc"})

      assert {:ok, _} = Catalog.create_category(%{name: "Services", slug: "root-svc"})
    end

    test "update_category/2 does not re-parent a category" do
      assert {:ok, parent} = Catalog.create_category(%{name: "Parent", slug: "parent"})
      assert {:ok, category} = Catalog.create_category(%{name: "Child", slug: "child"})

      {:ok, updated} = Catalog.update_category(category, %{name: "Renamed", parent_id: parent.id})

      assert updated.name == "Renamed"
      assert updated.parent_id == nil
    end

    test "create_child_category/2 refuses an archived parent" do
      assert {:ok, category} = Catalog.create_category(%{name: "Archived", slug: "archived"})
      assert {:ok, archived} = Catalog.archive_category(category)

      assert {:error, changeset} =
               Catalog.create_child_category(archived, %{name: "Kid", slug: "kid"})

      assert "cannot add categories under an archived category" in errors_on(changeset).base
    end

    test "archiving a parent hides the parent but leaves children individually reachable" do
      assert {:ok, category} = Catalog.create_category(%{name: "Old", slug: "old"})
      assert {:ok, child} = Catalog.create_child_category(category, %{name: "Kid", slug: "kid"})
      assert {:ok, _} = Catalog.archive_category(category)

      assert Catalog.get_public_category_by_slug("old") == nil
      assert Catalog.list_public_categories() == []
      assert Catalog.get_category_by_slug("old").status == :archived

      # Active children remain individually reachable by direct URL at this milestone;
      # they are simply not surfaced through navigation rooted at active categories.
      assert reached = Catalog.get_public_category_by_slug("kid")
      assert reached.status == :active
      assert reached.id == child.id
    end

    test "archived categories cannot be modified and cannot be archived twice" do
      assert {:ok, category} = Catalog.create_category(%{name: "Old", slug: "old"})
      assert {:ok, archived} = Catalog.archive_category(category)

      assert {:error, changeset} = Catalog.update_category(archived, %{name: "Renamed"})
      assert "archived categories cannot be modified" in errors_on(changeset).base

      assert {:error, changeset} = Catalog.archive_category(archived)
      assert "category is already archived" in errors_on(changeset).base
    end

    test "list_public_categories/0 returns only active roots with active children" do
      assert {:ok, root} = Catalog.create_category(%{name: "Root", slug: "root"})

      assert {:ok, active_child} =
               Catalog.create_child_category(root, %{name: "Active", slug: "ac"})

      assert {:ok, archived_child} =
               Catalog.create_child_category(root, %{name: "Hidden", slug: "hc"})

      assert {:ok, _} = Catalog.archive_category(archived_child)

      assert [root] = Catalog.list_public_categories()
      assert root.name == "Root"
      assert [child] = root.children
      assert child.id == active_child.id
    end

    test "list_child_categories/1 returns only active children" do
      assert {:ok, root} = Catalog.create_category(%{name: "Root", slug: "root"})
      assert {:ok, c1} = Catalog.create_child_category(root, %{name: "One", slug: "c1"})
      assert {:ok, c2} = Catalog.create_child_category(root, %{name: "Two", slug: "c2"})
      assert {:ok, _} = Catalog.archive_category(c2)

      assert [one] = Catalog.list_child_categories(root)
      assert one.id == c1.id
    end
  end

  describe "products" do
    defp category_attrs, do: %{name: "Digital Products", slug: "digital-products"}

    defp product_attrs(overrides \\ %{}) do
      Map.merge(
        %{
          name: "Sample Product",
          slug: "sample-product",
          product_type: :digital_product,
          visibility: :public
        },
        overrides
      )
    end

    defp create_published!(overrides \\ %{}, product_overrides \\ %{}) do
      attrs = Map.merge(product_attrs(), product_overrides)
      {:ok, category} = Catalog.create_category(overrides[:category] || category_attrs())
      {:ok, product} = Catalog.create_product(category, attrs)
      {:ok, published} = Catalog.publish_product(product)
      {category, published}
    end

    test "create_product/2 requires an active category and default values" do
      {:ok, category} = Catalog.create_category(category_attrs())

      assert {:ok, product} =
               Catalog.create_product(category, Map.drop(product_attrs(), [:visibility]))

      assert product.category_id == category.id
      assert product.status == :draft
      assert product.visibility == :private
      assert product.published_at == nil
    end

    test "create_product/2 refuses an archived category" do
      {:ok, category} = Catalog.create_category(category_attrs())
      {:ok, archived} = Catalog.archive_category(category)

      assert {:error, changeset} = Catalog.create_product(archived, product_attrs())
      assert "cannot add products to an archived category" in errors_on(changeset).category_id
    end

    test "create_product/2 validates required fields and slug format" do
      {:ok, category} = Catalog.create_category(category_attrs())

      assert {:error, changeset} = Catalog.create_product(category, %{})

      assert errors_on(changeset) == %{
               name: ["can't be blank"],
               slug: ["can't be blank"],
               product_type: ["can't be blank"]
             }

      assert {:error, changeset} =
               Catalog.create_product(
                 category,
                 product_attrs(%{slug: "Bad Slug", product_type: :ai_tool})
               )

      assert "must be lowercase letters, numbers, and single hyphens" in errors_on(changeset).slug
    end

    test "create_product/2 rejects duplicate slugs" do
      {:ok, category} = Catalog.create_category(category_attrs())
      assert {:ok, _} = Catalog.create_product(category, product_attrs())
      assert {:error, changeset} = Catalog.create_product(category, product_attrs())
      assert "has already been taken" in errors_on(changeset).slug
    end

    test "create_product/2 validates canonical_url when present" do
      {:ok, category} = Catalog.create_category(category_attrs())

      assert {:ok, _} =
               Catalog.create_product(
                 category,
                 product_attrs(%{canonical_url: "https://sales.site/x"})
               )

      assert {:error, changeset} =
               Catalog.create_product(category, product_attrs(%{canonical_url: "ftp://nope"}))

      assert "must be an absolute http(s) URL" in errors_on(changeset).canonical_url
    end

    test "update_product/2 freezes the slug once published" do
      {category, published} = create_published!()
      assert {:ok, _} = Catalog.update_product(published, %{name: "Renamed"})

      assert {:error, changeset} =
               Catalog.update_product(published, %{slug: "new-slug"})

      assert "cannot be changed once the product is published" in errors_on(changeset).slug

      assert {:ok, draft} =
               Catalog.create_product(category, product_attrs(%{slug: "draft-slug"}))

      assert {:ok, moved} = Catalog.update_product(draft, %{slug: "draft-slug-2"})
      assert moved.slug == "draft-slug-2"
    end

    test "update_product/2 refuses archived products" do
      {_category, published} = create_published!()
      {:ok, archived} = Catalog.archive_product(published)

      assert {:error, changeset} = Catalog.update_product(archived, %{name: "Nope"})
      assert "archived products cannot be modified" in errors_on(changeset).base
    end

    test "publish_product/1 stamps published_at and rejects non-drafts" do
      {_category, published} = create_published!()
      assert published.status == :published
      assert published.published_at != nil

      assert {:error, changeset} = Catalog.publish_product(published)
      assert "only draft products can be published" in errors_on(changeset).status
    end

    test "publish_product/1 refuses products in archived categories" do
      {:ok, category} = Catalog.create_category(category_attrs())
      {:ok, product} = Catalog.create_product(category, product_attrs())
      {:ok, _} = Catalog.archive_category(category)

      assert {:error, changeset} = Catalog.publish_product(product)
      assert "cannot publish products in an archived category" in errors_on(changeset).category_id
    end

    test "archive_product/1 removes products from public queries" do
      {_category, published} = create_published!()
      assert [_] = Catalog.list_public_products()
      {:ok, archived} = Catalog.archive_product(published)
      assert archived.status == :archived
      assert Catalog.list_public_products() == []
      assert Catalog.get_public_product_by_slug("sample-product") == nil

      assert {:error, changeset} = Catalog.archive_product(archived)
      assert "product is already archived" in errors_on(changeset).base
    end
  end

  describe "public product queries" do
    setup do
      {:ok, category} =
        Catalog.create_category(%{name: "Digital Products", slug: "digital-products"})

      {:ok, product} =
        Catalog.create_product(category, %{
          name: "Public Product",
          slug: "public-product",
          product_type: :digital_product,
          visibility: :public
        })

      {:ok, published} = Catalog.publish_product(product)
      %{category: category, product: published}
    end

    test "list_public_products/0 includes published public products", %{product: product} do
      assert [listed] = Catalog.list_public_products()
      assert listed.id == product.id
      assert listed.category.name == "Digital Products"
    end

    test "list_public_products/0 excludes drafts, archived, and private items", %{
      category: category
    } do
      {:ok, draft} =
        Catalog.create_product(category, %{
          name: "Draft",
          slug: "draft-item",
          product_type: :ai_tool,
          visibility: :public
        })

      {:ok, archived} =
        Catalog.create_product(category, %{
          name: "Archived",
          slug: "archived-item",
          product_type: :ai_tool,
          visibility: :public
        })

      {:ok, _} = Catalog.publish_product(archived)
      {:ok, _} = Catalog.archive_product(archived)

      {:ok, private} =
        Catalog.create_product(category, %{
          name: "Private",
          slug: "private-item",
          product_type: :ai_tool,
          visibility: :private
        })

      {:ok, _} = Catalog.publish_product(private)

      slugs = Enum.map(Catalog.list_public_products(), & &1.slug)
      refute Enum.member?(slugs, draft.slug)
      refute Enum.member?(slugs, archived.slug)
      refute Enum.member?(slugs, private.slug)
    end

    test "list_public_products/0 excludes unlisted but serves them by direct lookup",
         %{category: category} do
      {:ok, unlisted} =
        Catalog.create_product(category, %{
          name: "Unlisted",
          slug: "unlisted-item",
          product_type: :ai_tool,
          visibility: :unlisted
        })

      {:ok, published} = Catalog.publish_product(unlisted)

      refute Enum.member?(Enum.map(Catalog.list_public_products(), & &1.slug), "unlisted-item")
      assert Catalog.get_public_product_by_slug("unlisted-item").id == published.id
    end

    test "list_public_products/0 excludes not-yet-due products", %{category: category} do
      {:ok, future} =
        Catalog.create_product(category, %{
          name: "Future",
          slug: "future-item",
          product_type: :ai_tool,
          visibility: :public
        })

      {:ok, published} = Catalog.publish_product(future)

      {:ok, scheduled} =
        published
        |> Ecto.Changeset.change(
          published_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(3600)
        )
        |> Cass.Repo.update()

      assert published_at = scheduled.published_at
      assert DateTime.compare(published_at, DateTime.utc_now()) == :gt
      refute Enum.member?(Enum.map(Catalog.list_public_products(), & &1.slug), "future-item")
      assert Catalog.get_public_product_by_slug("future-item") == nil
    end

    test "public queries exclude products in archived categories", %{category: category} do
      assert [_] = Catalog.list_public_products()
      {:ok, _} = Catalog.archive_category(category)

      assert Catalog.list_public_products() == []
      assert Catalog.get_public_product_by_slug("public-product") == nil
    end

    test "list_public_products_by_category/1 returns only direct products", %{category: category} do
      {:ok, child} = Catalog.create_child_category(category, %{name: "Child", slug: "child"})

      {:ok, nested} =
        Catalog.create_product(child, %{
          name: "Nested",
          slug: "nested-item",
          product_type: :ai_tool,
          visibility: :public
        })

      {:ok, _} = Catalog.publish_product(nested)

      assert [only] = Catalog.list_public_products_by_category(category)
      assert only.slug == "public-product"
      assert [nested_only] = Catalog.list_public_products_by_category(child)
      assert nested_only.slug == "nested-item"
    end

    test "get_public_product_by_slug/1 returns nil for unknown and private slugs", %{
      product: product
    } do
      assert Catalog.get_public_product_by_slug("public-product").id == product.id
      assert Catalog.get_public_product_by_slug("nope") == nil

      {:ok, private} =
        Catalog.create_product(product.category, %{
          name: "Private",
          slug: "private-item",
          product_type: :ai_tool,
          visibility: :private
        })

      {:ok, _} = Catalog.publish_product(private)
      assert Catalog.get_public_product_by_slug("private-item") == nil
    end
  end
end
