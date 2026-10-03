defmodule Cass.Ai.ConcurrencyTest do
  @moduledoc """
  The credit pool under concurrent runs.

  Runs with `async: false`: the shared SQL sandbox lets several processes reach
  the same connection, which is the closest this suite gets to real load.

  A quota is only real if the database enforces it, because in production the
  gate is not a request counter in a LiveView process — it is one conditional
  `UPDATE` two buyers' tabs can reach at the same millisecond. So each test here
  fires a burst at a deliberately tiny pool and asserts on what the rows say
  afterwards, which is the only version of "cannot overspend" that a retry, a
  second tab, or a second node cannot undo.
  """
  use Cass.DataCase, async: false

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Ai
  alias Cass.Ai.Completion
  alias Cass.Ai.CreditBalance
  alias Cass.Ai.Run
  alias Cass.Repo

  @no_credits "you have no AI credits left"

  setup do
    category = category_fixture()
    buyer = Scope.for_user(user_fixture())

    # One credit, so the very first run exhausts the pool and every concurrent
    # caller after it must lose. A larger pool would let an off-by-one through.
    granted =
      granted_entitlement_fixture(buyer, category,
        product_type: :ai,
        config: %{"credits" => 1, "model" => "fast"}
      )

    %{
      category: category,
      buyer: buyer,
      granted: granted,
      entitlement_id: granted.entitlement.id
    }
  end

  defp stub_gateway do
    Req.Test.stub(:nexus_ai, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "an answer"}}]
      })
    end)
  end

  defp remaining(buyer, entitlement_id) do
    buyer |> Ai.balance(entitlement_id) |> CreditBalance.remaining()
  end

  test "concurrent runs of a one-credit purchase grant exactly one completion", ctx do
    stub_gateway()

    tasks =
      for _attempt <- 1..6 do
        Task.async(fn -> Ai.complete(ctx.buyer, ctx.entitlement_id, "hello") end)
      end

    results = Task.await_many(tasks, :infinity)

    # The quota is the contract: one credit bought one run, so five callers are
    # told there are no credits left.
    assert Enum.count(results, &match?({:ok, %Completion{}}, &1)) == 1

    assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 5

    for {:error, changeset} <- results do
      assert @no_credits in errors_on(changeset).base
    end
  end

  test "concurrent runs never drive a balance below its granted total", ctx do
    stub_gateway()

    tasks =
      for _attempt <- 1..8 do
        Task.async(fn -> Ai.complete(ctx.buyer, ctx.entitlement_id, "hello") end)
      end

    Task.await_many(tasks, :infinity)

    balance = Ai.balance(ctx.buyer, ctx.entitlement_id)

    # The row is the source of truth, not the sum of the returns: this is what a
    # billing audit reads.
    assert balance.granted == 1
    assert balance.consumed == 1
    assert balance.consumed <= balance.granted
    assert remaining(ctx.buyer, ctx.entitlement_id) == 0
  end

  test "only the runs that were paid for are logged as succeeded", ctx do
    stub_gateway()

    tasks =
      for _attempt <- 1..6 do
        Task.async(fn -> Ai.complete(ctx.buyer, ctx.entitlement_id, "hello") end)
      end

    Task.await_many(tasks, :infinity)

    runs = Ai.recent_runs(ctx.buyer, ctx.entitlement_id, 10)
    succeeded = Enum.count(runs, &(&1.status == :succeeded))

    # Every attempt is logged, so the refusals are explainable to a buyer and to
    # support, but only one of them consumed anything.
    assert succeeded == 1
    assert length(runs) == 6
    assert Repo.aggregate(from(r in Run, where: r.status == :succeeded), :count) == 1
  end

  test "a concurrent burst on a larger pool spends each credit exactly once", ctx do
    granted =
      granted_entitlement_fixture(ctx.buyer, ctx.category,
        product_type: :ai,
        config: %{"credits" => 3}
      )

    stub_gateway()

    tasks =
      for _attempt <- 1..10 do
        Task.async(fn -> Ai.complete(ctx.buyer, granted.entitlement.id, "hello") end)
      end

    results = Task.await_many(tasks, :infinity)

    # Three credits, three completions — and the balance agrees, rather than the
    # count coming only from the callers' return values.
    assert Enum.count(results, &match?({:ok, %Completion{}}, &1)) == 3

    balance = Ai.balance(ctx.buyer, granted.entitlement.id)
    assert balance.consumed == 3
    assert CreditBalance.remaining(balance) == 0
  end

  test "concurrent failing runs all refund, leaving the pool whole", ctx do
    granted =
      granted_entitlement_fixture(ctx.buyer, ctx.category,
        product_type: :ai,
        config: %{"credits" => 3}
      )

    Req.Test.stub(:nexus_ai, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "unavailable"})
    end)

    tasks =
      for _attempt <- 1..6 do
        Task.async(fn -> Ai.complete(ctx.buyer, granted.entitlement.id, "hello") end)
      end

    results = Task.await_many(tasks, :infinity)

    assert Enum.all?(results, &match?({:error, %Ecto.Changeset{}}, &1))

    # An outage is not a sale: nothing was delivered, so nothing is charged.
    balance = Ai.balance(ctx.buyer, granted.entitlement.id)
    assert balance.consumed == 0
    assert CreditBalance.remaining(balance) == 3
  end

  test "concurrent issuance of the same entitlement yields one balance", ctx do
    tasks =
      for _attempt <- 1..6 do
        Task.async(fn -> Ai.issue_credits(ctx.granted.entitlement) end)
      end

    results = Task.await_many(tasks, :infinity)

    ids = for {:ok, balance} <- results, do: balance.id
    assert ids == List.duplicate(hd(ids), length(ids))

    assert Repo.aggregate(
             from(b in CreditBalance, where: b.entitlement_id == ^ctx.entitlement_id),
             :count
           ) == 1
  end

  test "a foreign buyer cannot drain a pool by racing its owner", ctx do
    stranger = Scope.for_user(user_fixture())
    stub_gateway()

    tasks =
      for _attempt <- 1..4 do
        Task.async(fn -> Ai.complete(ctx.buyer, ctx.entitlement_id, "mine") end)
      end ++
        for _attempt <- 1..4 do
          Task.async(fn -> Ai.complete(stranger, ctx.entitlement_id, "not mine") end)
        end

    results = Task.await_many(tasks, :infinity)

    owner_successes =
      results
      |> Enum.count(&match?({:ok, %Completion{}}, &1))

    # Whatever interleaving the scheduler chose, the stranger never gets an
    # answer and never costs the owner a credit.
    assert owner_successes == 1
    assert remaining(ctx.buyer, ctx.entitlement_id) == 0
  end
end
