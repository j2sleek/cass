defmodule Cass.Repo.Migrations.CreateProductVariantsAndProductTypes do
  use Ecto.Migration

  # Moves the catalog onto the product-centric vocabulary: every type is a
  # Product, product type is one of digital/smm/ai/service, and purchasable
  # configurations live on variants (pricing is a variant concern, not a
  # product-level one).
  #
  # The table swap order matters: the CHECK constraint is dropped *before* the
  # data migration and recreated *after* it, so at no moment does an existing
  # row violate it.

  def up do
    drop constraint(:cass_products, :cass_products_product_type_check)

    execute("""
    UPDATE cass_products
    SET product_type = CASE product_type
      WHEN 'digital_product' THEN 'digital'
      WHEN 'smm_service' THEN 'smm'
      WHEN 'ai_tool' THEN 'ai'
    END
    WHERE product_type IN ('digital_product', 'smm_service', 'ai_tool')
    """)

    create constraint(:cass_products, :cass_products_product_type_check,
             check: "product_type in ('digital', 'smm', 'ai', 'service')"
           )

    alter table(:cass_products) do
      add :featured, :boolean, null: false, default: false
    end

    create table(:cass_product_variants) do
      add :name, :string, null: false
      add :sku, :string
      # Integer minor units (e.g. 1250 == $12.50). `NULL` means the variant is
      # not priced yet; nothing in this milestone is a free item, so a price is
      # a seller's choice, not a value we fabricate.
      add :price_cents, :integer
      add :currency, :string, null: false, default: "USD"
      # `NULL` means unlimited supply.
      add :stock, :integer
      add :active, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0
      # Type-specific purchasable configuration, e.g. SMM quantity ranges and
      # platform, AI provider/model/duration. Kept as JSONB until a field
      # provably needs to be queryable.
      add :config, :map, null: false, default: %{}

      add :product_id,
          references(:cass_products, on_delete: :restrict, on_update: :update_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cass_product_variants, [:product_id])
    create index(:cass_product_variants, [:active])

    create unique_index(:cass_product_variants, [:product_id, "lower(name)"],
             name: :cass_product_variants_product_name_index
           )

    create unique_index(:cass_product_variants, [:sku],
             where: "sku is not null",
             name: :cass_product_variants_sku_index
           )
  end

  def down do
    drop table(:cass_product_variants)

    alter table(:cass_products) do
      remove :featured
    end

    drop constraint(:cass_products, :cass_products_product_type_check)

    execute("""
    UPDATE cass_products
    SET product_type = CASE product_type
      WHEN 'digital' THEN 'digital_product'
      WHEN 'smm' THEN 'smm_service'
      WHEN 'ai' THEN 'ai_tool'
    END
    WHERE product_type IN ('digital', 'smm', 'ai')
    """)

    create constraint(:cass_products, :cass_products_product_type_check,
             check: "product_type in ('digital_product', 'smm_service', 'ai_tool')"
           )
  end
end
