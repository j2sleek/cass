defmodule Cass.Orders.ConcurrencyTest do
  @moduledoc """
  Stock reservations under concurrent checkout attempts.

  Runs with `async: false`: the shared SQL sandbox lets multiple processes
  exercise the same connection, which is the closest the unit test suite can
  get to real load. The guarantee under test is the database one — the
  reservation is an atomic conditional `UPDATE ... WHERE stock >= qty`, so no
  interleaving of transactions can ever push stock below zero or grant two
  orders the same unit.
  """
  use Cass.DataCase, async: false

  import Cass.AccountsFixtures

  alias Cass.Accounts.Scope
  alias Cass.Catalog
  alias Cass.Orders

  setup do
    {:ok, category} = Catalog.create_category(%{name: "Digital", slug: "digital"})
    owner = Scope.for_user(vendor_fixture())

    {:ok, product} =
      Catalog.create_owned_product(owner, category, %{
        name: "Concurrent",
        slug: "concurrent",
        product_type: :digital,
        visibility: :public
      })

    {:ok, product} = Catalog.publish_product(owner, product)

    {:ok, variant} =
      Catalog.create_variant(owner, product, %{
        name: "10 seats",
        sku: "SEATS-#{System.unique_integer([:positive])}",
        price_cents: 1000,
        currency: "USD",
        stock: 10,
        sort_order: 1
      })

    %{variant: variant}
  end

  test "two purchases together cannot take more units than the variant has",
       %{variant: variant} do
    buyer_a = Scope.for_user(user_fixture())
    buyer_b = Scope.for_user(user_fixture())

    task_a =
      Task.async(fn ->
        {buyer_a, Orders.create_order(buyer_a, [%{product_variant_id: variant.id, quantity: 6}])}
      end)

    task_b =
      Task.async(fn ->
        {buyer_b, Orders.create_order(buyer_b, [%{product_variant_id: variant.id, quantity: 6}])}
      end)

    results = [Task.await(task_a, :infinity), Task.await(task_b, :infinity)]

    # Exactly one of the two succeeds; the loser fails on out-of-stock.
    assert results |> Enum.count(&match?({_buyer, {:ok, _order}}, &1)) == 1
    assert results |> Enum.count(&match?({_buyer, {:error, _changeset}}, &1)) == 1

    {loser, {:error, loser_changeset}} = Enum.find(results, &match?({_buyer, {:error, _}}, &1))
    assert "an item in the order is out of stock" in errors_on(loser_changeset).base

    # The loser's account has no order; the winner's does.
    assert Orders.list_orders(loser) == []

    # Stock ends exactly where the successful purchase left it, never negative.
    assert Cass.Repo.get!(Catalog.ProductVariant, variant.id).stock == 4
  end

  test "many buyers can take exactly the available stock and no more",
       %{variant: variant} do
    quantities = [1, 2, 3, 4, 5]
    available = 10

    tasks =
      for quantity <- quantities do
        buyer = Scope.for_user(user_fixture())

        Task.async(fn ->
          Orders.create_order(buyer, [%{product_variant_id: variant.id, quantity: quantity}])
        end)
      end

    results = Task.await_many(tasks, :infinity)

    sold = results |> Enum.filter(&match?({:ok, _}, &1)) |> length()
    assert sold == 4

    bought =
      results
      |> Enum.flat_map(fn
        {:ok, order} ->
          Enum.map(order.order_items, & &1.quantity)

        {:error, _changeset} ->
          []
      end)
      |> Enum.sum()

    assert bought == available
    assert Cass.Repo.get!(Catalog.ProductVariant, variant.id).stock == 0
  end
end
