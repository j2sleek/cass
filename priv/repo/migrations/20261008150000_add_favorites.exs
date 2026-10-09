defmodule Cass.Repo.Migrations.AddFavorites do
  use Ecto.Migration

  # A saved item ("favorite"): one row per (user, product), so a signed-in
  # account can pin products it is following before (or without) buying them.
  #
  # `on_delete: :restrict` matches the rest of the marketplace: an account with
  # saved items, or a product that has been pinned, is protected history that
  # cannot be silently destroyed (products are archived, never deleted). The
  # composite unique index is the identity of a favorite — saving the same
  # product twice is the same pin, which is what makes `add_favorite/2`
  # idempotent. The `product_id` index backs the "who saved this product?" read
  # used by the seller surface later and keeps removal lookups fast.

  def change do
    create table(:cass_favorites) do
      add :user_id,
          references(:cass_users, on_delete: :restrict, on_update: :update_all),
          null: false

      add :product_id,
          references(:cass_products, on_delete: :restrict, on_update: :update_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cass_favorites, [:user_id, :product_id])
    create index(:cass_favorites, [:product_id])
  end
end
