defmodule Cass.Repo.Migrations.AddOwnerToCassProducts do
  use Ecto.Migration

  def change do
    alter table(:cass_products) do
      # `owner_id IS NULL` is a platform-owned product, so the column has to be
      # nullable: every product created before this migration belongs to the
      # platform and no backfill (or fabricated user) is needed to keep it.
      #
      # `ON DELETE RESTRICT` is deliberate and matches the catalog's own
      # `category_id` foreign key. A cascade would be the only hard-delete path
      # in the product lifecycle, and a `SET NULL` would silently turn a
      # seller's product into a platform product when their account is removed.
      # Restricting keeps revenue attribution intact and forces whoever removes
      # an account to decide explicitly what happens to the products it owns.
      add :owner_id,
          references(:cass_users, on_delete: :restrict, on_update: :update_all),
          index: false
    end

    # A product has at most one owner, but many products may share one owner, so
    # this is a plain index rather than a unique one. It serves the owner-scoped
    # management queries ("products owned by this seller").
    create index(:cass_products, [:owner_id])
  end
end
