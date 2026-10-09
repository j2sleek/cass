defmodule Cass.Favorites do
  @moduledoc """
  Saved items ("favorites"): the retention pin a signed-in account puts on a
  product it is following.

  ## Shape

  A favorite is a `(user, product)` pair and nothing else. Saving is
  idempotent and un-saving never raises, and both are scoped like every other
  customer surface in the marketplace: a guest simply has no favorites
  (`list_favorite_products/1` and `favorite_ids_for/1` return empty,
  `add_favorite/2` refuses), and a favorite always belongs to the account that
  created it
  (`Cass.Accounts.Scope` supplies the user — nothing about a request can name
  another user).

  ## Reading favorites back

  Listing resolves each pinned product through the catalog's public query
  contract (`Cass.Catalog.list_public_products_by_ids/1`), so a product that
  was later archived, wiped from its category, or made `:private` simply drops
  out of the list — the marketplace never advertises something it would refuse
  to serve, and never probes rows it would refuse to show. The pin itself is
  kept, so an un-archive brings the product back.
  """

  import Ecto.Query, warn: false

  alias Cass.Accounts.{Scope, User}
  alias Cass.Catalog.Product
  alias Cass.Favorites.Favorite
  alias Cass.Repo
  alias Ecto.Changeset

  @doc """
  Returns the products the caller has saved, most recently saved first.

  Only products that are still publicly reachable are returned; a product that
  has been archived or made private since it was pinned disappears from the
  list (the pin itself stays, so an un-archive brings it back).
  """
  def list_favorite_products(%Scope{user: %User{}} = scope) do
    user_id = scope.user.id

    saved =
      Repo.all(
        from f in Favorite,
          where: f.user_id == ^user_id,
          order_by: [desc: f.inserted_at, desc: f.id],
          select: {f.product_id, f.inserted_at}
      )

    saved_at = Map.new(saved)

    saved
    |> Enum.map(&elem(&1, 0))
    |> Cass.Catalog.list_public_products_by_ids()
    |> Enum.sort_by(&Map.get(saved_at, &1.id), {:desc, DateTime})
  end

  def list_favorite_products(_scope), do: []

  @doc "Returns the product ids the caller has saved, most recently saved first."
  def favorite_ids_for(%Scope{user: %User{}} = scope) do
    user_id = scope.user.id

    Repo.all(
      from f in Favorite,
        where: f.user_id == ^user_id,
        order_by: [desc: f.inserted_at, desc: f.id],
        select: f.product_id
    )
  end

  def favorite_ids_for(_scope), do: []

  @doc "Returns `true` when the caller has saved `product_id`."
  def favorited?(%Scope{user: %User{}} = scope, product_id) when is_integer(product_id) do
    user_id = scope.user.id

    Repo.exists?(from f in Favorite, where: f.user_id == ^user_id and f.product_id == ^product_id)
  end

  def favorited?(_scope, _product_id), do: false

  @doc """
  Saves a product for the caller.

  Idempotent: saving a product that is already saved keeps the single pin and
  returns the existing row. A guest scope is refused with a `:base` error.
  """
  def add_favorite(%Scope{user: %User{}} = scope, %Product{} = product) do
    user_id = scope.user.id
    product_id = product.id

    changeset =
      %Favorite{}
      |> Favorite.changeset(%{})
      |> Changeset.put_change(:user_id, user_id)
      |> Changeset.put_change(:product_id, product_id)

    # `ON CONFLICT DO NOTHING` is the idempotency mechanism, the same one the
    # entitlement grant uses: the unique pair decides, not a preceding read, so
    # two concurrent saves of the same product cannot race into a raised index
    # violation. A conflict returns a struct with no id, and the stored pin —
    # this account's, for this product — is handed back.
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:user_id, :product_id]) do
      {:ok, %Favorite{id: nil}} ->
        case Repo.get_by(Favorite, user_id: user_id, product_id: product_id) do
          # The pin vanished between the two statements (a concurrent un-save),
          # so the pair is free again and the insert is simply retried.
          nil -> Repo.insert(changeset)
          favorite -> {:ok, favorite}
        end

      result ->
        result
    end
  end

  def add_favorite(_scope, _product) do
    {:error, not_authenticated_changeset()}
  end

  @doc """
  Removes the caller's pin on a product.

  Idempotent: removing a product that is not saved is a no-op. Always returns
  `:ok`, for guests included.
  """
  def remove_favorite(%Scope{user: %User{}} = scope, %Product{} = product) do
    user_id = scope.user.id
    product_id = product.id

    Repo.delete_all(
      from f in Favorite, where: f.user_id == ^user_id and f.product_id == ^product_id
    )

    :ok
  end

  def remove_favorite(_scope, _product), do: :ok

  defp not_authenticated_changeset do
    %Favorite{}
    |> Changeset.change()
    |> Changeset.add_error(:base, "you must be signed in to save a product")
  end
end
