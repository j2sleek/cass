defmodule Cass.Favorites.Favorite do
  @moduledoc """
  A saved item in the marketplace ("favorite").

  A favorite is the pair `(user_id, product_id)`: one row per account per
  product, enforced by the `cass_favorites_user_id_product_id_index` unique
  index, so saving is naturally idempotent. Foreign keys are `on_delete:
  :restrict` at the database — an account with saved items, or a product that
  has been pinned, is protected history that cannot be destroyed (products are
  archived, never deleted).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Cass.Accounts.User
  alias Cass.Catalog.Product

  schema "cass_favorites" do
    belongs_to :user, User
    belongs_to :product, Product

    timestamps(type: :utc_datetime)
  end

  @doc false
  # `user_id` and `product_id` are never cast: they are set programmatically by
  # `Cass.Favorites` from the authenticated scope and the resolved product, so
  # a request can never save a favorite on somebody else's behalf. The
  # changeset exists to spell out the database constraints (a unique pair, and
  # both references must exist).
  def changeset(favorite, attrs) do
    favorite
    |> cast(attrs, [])
    |> unique_constraint([:user_id, :product_id])
    |> assoc_constraint(:user)
    |> assoc_constraint(:product)
  end
end
