defmodule Cass.Repo.Migrations.CreateCatalog do
  use Ecto.Migration

  def change do
    create table(:cass_categories) do
      add :parent_id, references(:cass_categories, on_delete: :restrict, on_update: :update_all)
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :seo_title, :string
      add :seo_description, :string
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create constraint(:cass_categories, :cass_categories_status_check,
             check: "status in ('active', 'archived')"
           )

    create index(:cass_categories, [:slug], unique: true)
    create index(:cass_categories, [:parent_id])
    create index(:cass_categories, [:status])

    create unique_index(:cass_categories, ["lower(name)"],
             where: "parent_id is null",
             name: :cass_categories_root_name_index
           )

    create unique_index(:cass_categories, [:parent_id, "lower(name)"],
             where: "parent_id is not null",
             name: :cass_categories_sibling_name_index
           )

    create table(:cass_products) do
      add :category_id,
          references(:cass_categories, on_delete: :restrict, on_update: :update_all),
          null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :product_type, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :visibility, :string, null: false, default: "private"
      add :short_description, :string
      add :description, :text
      add :seo_title, :string
      add :seo_description, :string
      add :canonical_url, :string
      add :published_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create constraint(:cass_products, :cass_products_product_type_check,
             check: "product_type in ('digital_product', 'smm_service', 'ai_tool')"
           )

    create constraint(:cass_products, :cass_products_status_check,
             check: "status in ('draft', 'published', 'archived')"
           )

    create constraint(:cass_products, :cass_products_visibility_check,
             check: "visibility in ('public', 'unlisted', 'private')"
           )

    create index(:cass_products, [:slug], unique: true)
    create index(:cass_products, [:category_id])
    create index(:cass_products, [:status, :visibility])
    create index(:cass_products, [:published_at])
  end
end
