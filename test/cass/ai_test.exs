defmodule Cass.AiTest do
  @moduledoc """
  Domain tests for the AI leg: what a fulfilled AI purchase grants, and what
  spending it looks like.

  Everything starts from a real purchase driven through the real delivery
  transitions, exactly as `test/cass/delivery_test.exs` does — so "this buyer
  holds credits" is standing on the state production creates, not a fabricated
  balance.

  They are organised around the questions the context answers, and the order
  matters: **what is granted**, then **what may be spent**, then **who may spend
  it**, then **what happens when the gateway misbehaves**.
  """
  use Cass.DataCase, async: true

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Ai
  alias Cass.Ai.Completion
  alias Cass.Ai.CreditBalance
  alias Cass.Entitlements.Entitlement
  alias Cass.Repo

  @refused "this AI purchase cannot be run"
  @no_credits "you have no AI credits left"
  @throttled "you are sending requests too quickly"
  @too_long "that prompt is too long"

  setup do
    category = category_fixture()
    buyer = Scope.for_user(user_fixture())

    granted =
      granted_entitlement_fixture(buyer, category,
        product_type: :ai,
        config: %{"credits" => 5, "model" => "fast"}
      )

    %{
      category: category,
      buyer: buyer,
      stranger: Scope.for_user(user_fixture()),
      granted: granted
    }
  end

  defp max_runs do
    :cass
    |> Application.get_env(Cass.Ai, [])
    |> Keyword.get(:rate_limit, [])
    |> Keyword.fetch!(:max_runs)
  end

  defp stub_gateway(content \\ "the answer") do
    Req.Test.stub(:nexus_ai, fn conn ->
      Req.Test.json(conn, %{
        "id" => "chatcmpl-test",
        "model" => "fast",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
      })
    end)
  end

  defp stub_failing_gateway do
    Req.Test.stub(:nexus_ai, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
    end)
  end

  describe "what a fulfilled AI purchase is owed" do
    test "the pool comes from the ordered variant's snapshot", %{granted: granted} do
      assert %CreditBalance{} = balance = Ai.balance(granted.buyer, granted.entitlement.id)
      assert balance.granted == 5
      assert balance.consumed == 0
      assert CreditBalance.remaining(balance) == 5
      assert balance.user_id == granted.buyer.user.id
    end

    test "it is issued inside the fulfillment transaction, not beside it", %{
      category: category,
      buyer: buyer
    } do
      {_product, variant} =
        published_variant_fixture(category, product_type: :ai, config: %{"credits" => 3})

      order = paid_order_fixture(buyer, variant)
      {:ok, [fulfillment]} = Cass.Fulfillment.create_for_paid_order(order)

      # Claimed but not delivered: the obligation exists, and nothing is owed to
      # the buyer yet.
      {:ok, claimed} = Cass.Fulfillment.mark_processing(fulfillment)
      entitlement = Repo.preload(claimed, :order_item).order_item
      assert Ai.balance(buyer, entitlement.id) == nil

      {:ok, delivered} = Cass.Fulfillment.mark_fulfilled(claimed)
      granted = Repo.preload(delivered, :entitlement).entitlement
      assert Ai.balance(buyer, granted.id).granted == 3
    end

    test "a non-AI purchase is owed no balance at all", %{category: category, buyer: buyer} do
      granted = granted_entitlement_fixture(buyer, category, product_type: :digital)

      # Absence, not zero: a digital purchase is not a spent AI pool.
      assert Ai.balance(buyer, granted.entitlement.id) == nil
    end

    test "re-running fulfillment grants nothing extra", %{granted: granted} do
      before = Ai.balance(granted.buyer, granted.entitlement.id)

      # The transition is terminal, so the real idempotency check is on the
      # issuance call itself, which a duplicate webhook could reach.
      assert {:ok, ^before} = Ai.issue_credits(granted.entitlement)

      assert [%CreditBalance{}] =
               Repo.all(
                 from b in CreditBalance, where: b.entitlement_id == ^granted.entitlement.id
               )
    end

    test "a variant that pins no usable credits is owed zero, not a default", %{
      category: category,
      buyer: buyer
    } do
      for config <- [%{}, %{"credits" => "lots"}, %{"credits" => -1}, %{"credits" => nil}] do
        granted =
          granted_entitlement_fixture(buyer, category, product_type: :ai, config: config)

        assert Ai.balance(buyer, granted.entitlement.id).granted == 0
      end
    end

    test "the pool is snapshotted, so a later catalog edit cannot rewrite it", %{
      granted: granted
    } do
      balance = Ai.balance(granted.buyer, granted.entitlement.id)
      assert balance.granted == 5

      # The entitlement's metadata is the purchase snapshot and nothing writes to
      # it; this asserts the balance reads *that*, not the live variant.
      assert Ai.granted_credits(granted.entitlement) == 5
    end
  end

  describe "balance/2" do
    test "somebody else's purchase is nil, not zero", %{granted: granted, stranger: stranger} do
      assert Ai.balance(stranger, granted.entitlement.id) == nil
    end

    test "a guest is nil", %{granted: granted} do
      assert Ai.balance(Scope.for_user(nil), granted.entitlement.id) == nil
    end

    test "an id that does not exist is nil", %{buyer: buyer} do
      assert Ai.balance(buyer, 999_999) == nil
      assert Ai.balance(buyer, "not-a-number") == nil
    end

    test "a revoked grant is nil", %{granted: granted} do
      granted = revoke_fixture(granted)

      assert Ai.balance(granted.buyer, granted.entitlement.id) == nil
    end

    test "an elapsed grant is nil", %{granted: granted} do
      expire_entitlement_fixture(granted.entitlement)

      assert Ai.balance(granted.buyer, granted.entitlement.id) == nil
    end
  end

  describe "complete/3 spends exactly one credit" do
    test "a successful run returns the completion and moves the balance", %{
      granted: granted,
      buyer: buyer
    } do
      stub_gateway("Rewritten: hi there.")

      assert {:ok, %Completion{} = completion} =
               Ai.complete(buyer, granted.entitlement.id, "rewrite this: hi")

      assert completion.content == "Rewritten: hi there."
      assert CreditBalance.remaining(Ai.balance(buyer, granted.entitlement.id)) == 4
    end

    test "the model comes from the purchase, never from the request", %{
      granted: granted,
      buyer: buyer
    } do
      Req.Test.stub(:nexus_ai, fn conn ->
        body = Req.Test.raw_body(conn) |> Jason.decode!()

        assert body["model"] == "fast"

        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
      end)

      assert {:ok, %Completion{}} = Ai.complete(buyer, granted.entitlement.id, "hello")
    end

    test "an unpinned model falls back to the gateway default", %{
      category: category,
      buyer: buyer
    } do
      granted =
        granted_entitlement_fixture(buyer, category,
          product_type: :ai,
          config: %{"credits" => 5}
        )

      Req.Test.stub(:nexus_ai, fn conn ->
        body = Req.Test.raw_body(conn) |> Jason.decode!()

        assert body["model"] == "default"

        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
      end)

      assert {:ok, %Completion{}} = Ai.complete(buyer, granted.entitlement.id, "hello")
    end

    test "repeated runs spend one credit each", %{granted: granted, buyer: buyer} do
      stub_gateway()

      for _attempt <- 1..3 do
        assert {:ok, %Completion{}} = Ai.complete(buyer, granted.entitlement.id, "hello")
      end

      assert CreditBalance.remaining(Ai.balance(buyer, granted.entitlement.id)) == 2
    end

    test "an exhausted pool is refused, and says so", %{category: category, buyer: buyer} do
      granted =
        granted_entitlement_fixture(buyer, category, product_type: :ai, config: %{"credits" => 1})

      stub_gateway()
      assert {:ok, %Completion{}} = Ai.complete(buyer, granted.entitlement.id, "hello")

      assert {:error, changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")
      assert @no_credits in errors_on(changeset).base

      # The refusal cost nothing, which is the property that makes the message
      # truthful.
      assert CreditBalance.remaining(Ai.balance(buyer, granted.entitlement.id)) == 0
    end

    test "a blank prompt is refused without spending a credit", %{
      granted: granted,
      buyer: buyer
    } do
      assert {:error, changeset} = Ai.complete(buyer, granted.entitlement.id, "   ")
      assert @refused in errors_on(changeset).base

      assert CreditBalance.remaining(Ai.balance(buyer, granted.entitlement.id)) == 5
    end

    test "an over-long prompt is refused on the server, before a credit moves", %{
      granted: granted,
      buyer: buyer
    } do
      # Deliberately unstubbed: the length rule belongs to the context, so
      # over-long input must be refused before any request is attempted.
      assert {:error, changeset} =
               Ai.complete(buyer, granted.entitlement.id, String.duplicate("a", 8_001))

      assert @too_long in errors_on(changeset).base

      assert CreditBalance.remaining(Ai.balance(buyer, granted.entitlement.id)) == 5
      assert Ai.recent_runs(buyer, granted.entitlement.id) == []
    end

    test "a prompt exactly at the limit is accepted", %{granted: granted, buyer: buyer} do
      stub_gateway()

      assert {:ok, %Completion{}} =
               Ai.complete(buyer, granted.entitlement.id, String.duplicate("a", 8_000))
    end
  end

  describe "complete/3 authorization" do
    test "somebody else's purchase is refused and costs them nothing", %{
      granted: granted,
      stranger: stranger
    } do
      # Deliberately not stubbed: a refusal must happen *before* any request, so
      # an unexpected HTTP call would raise rather than silently pass.
      assert {:error, changeset} = Ai.complete(stranger, granted.entitlement.id, "hello")
      assert @refused in errors_on(changeset).base

      assert CreditBalance.remaining(Ai.balance(granted.buyer, granted.entitlement.id)) == 5
    end

    test "a guest is refused", %{granted: granted} do
      assert {:error, changeset} =
               Ai.complete(Scope.for_user(nil), granted.entitlement.id, "hello")

      assert @refused in errors_on(changeset).base
    end

    test "a revoked grant is refused and writes no run", %{granted: granted, buyer: buyer} do
      granted = revoke_fixture(granted)

      assert {:error, changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")
      assert @refused in errors_on(changeset).base

      # A run row can only be attributed to a balance, and a refused grant has
      # no authorized path to one.
      assert Ai.recent_runs(buyer, granted.entitlement.id) == []
    end

    test "an elapsed grant is refused", %{granted: granted, buyer: buyer} do
      expire_entitlement_fixture(granted.entitlement)

      assert {:error, changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")
      assert @refused in errors_on(changeset).base
    end

    test "an unknown id and a foreign id are indistinguishable", %{
      granted: granted,
      stranger: stranger
    } do
      assert {:error, foreign} = Ai.complete(stranger, granted.entitlement.id, "hello")
      assert {:error, unknown} = Ai.complete(stranger, 999_999, "hello")

      assert errors_on(foreign).base == errors_on(unknown).base
    end

    test "a non-AI purchase is refused", %{category: category, buyer: buyer} do
      granted = granted_entitlement_fixture(buyer, category, product_type: :digital)

      assert {:error, changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")
      assert @refused in errors_on(changeset).base
    end

    test "a malformed scope or id is refused, not raised on", %{granted: granted} do
      assert {:error, _changeset} = Ai.complete(nil, granted.entitlement.id, "hello")
      assert {:error, _changeset} = Ai.complete(%{}, granted.entitlement.id, "hello")
      assert {:error, _changeset} = Ai.complete(Scope.for_user(nil), "nope", "hello")
    end
  end

  describe "the gateway misbehaving" do
    test "a 5xx refunds the credit, because it is CASS's failure", %{
      granted: granted,
      buyer: buyer
    } do
      stub_failing_gateway()

      assert {:error, changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")
      assert @refused in errors_on(changeset).base

      # The whole point: a buyer is never charged for an outage.
      assert CreditBalance.remaining(Ai.balance(buyer, granted.entitlement.id)) == 5
    end

    test "a failed run is logged as failed, with the reason", %{granted: granted, buyer: buyer} do
      stub_failing_gateway()

      assert {:error, _changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")

      assert [run] = Ai.recent_runs(buyer, granted.entitlement.id)
      assert run.status == :failed
      assert run.refusal_reason == "unavailable"
    end

    test "an unauthorized gateway also refunds", %{granted: granted, buyer: buyer} do
      Req.Test.stub(:nexus_ai, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "bad key"})
      end)

      assert {:error, _changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")
      assert CreditBalance.remaining(Ai.balance(buyer, granted.entitlement.id)) == 5
    end
  end

  describe "the run log" do
    test "records the outcome and the model, never the prompt", %{
      granted: granted,
      buyer: buyer
    } do
      stub_gateway("a completion")

      assert {:ok, %Completion{}} =
               Ai.complete(buyer, granted.entitlement.id, "my private draft")

      assert [run] = Ai.recent_runs(buyer, granted.entitlement.id)
      assert run.status == :succeeded
      assert run.model == "fast"
      assert run.prompt_chars == String.length("my private draft")

      # The text is the user's, and the log is operational: neither the prompt
      # nor the completion is stored anywhere.
      refute inspect(run) =~ "my private draft"
      refute inspect(run) =~ "a completion"
    end

    test "an exhausted pool is logged as a refusal", %{category: category, buyer: buyer} do
      granted =
        granted_entitlement_fixture(buyer, category, product_type: :ai, config: %{"credits" => 0})

      stub_gateway()

      assert {:error, _changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")

      assert [run] = Ai.recent_runs(buyer, granted.entitlement.id)
      assert run.status == :refused
      assert run.refusal_reason == @no_credits
    end

    test "somebody else cannot read the log", %{granted: granted, stranger: stranger} do
      stub_gateway()
      assert {:ok, %Completion{}} = Ai.complete(granted.buyer, granted.entitlement.id, "hello")

      assert Ai.recent_runs(stranger, granted.entitlement.id) == []
    end

    test "it is newest first and bounded", %{granted: granted, buyer: buyer} do
      stub_gateway()

      for _attempt <- 1..3 do
        assert {:ok, %Completion{}} = Ai.complete(buyer, granted.entitlement.id, "hello")
      end

      runs = Ai.recent_runs(buyer, granted.entitlement.id, 2)
      assert length(runs) == 2
      assert runs == Enum.sort_by(runs, & &1.id, :desc)
    end
  end

  describe "rate limiting" do
    test "a burst past the ceiling is refused, and the refusals cost nothing", %{
      granted: granted,
      buyer: buyer
    } do
      stub_gateway()
      max = max_runs()

      for _attempt <- 1..max do
        assert {:ok, %Completion{}} = Ai.complete(buyer, granted.entitlement.id, "hello")
      end

      assert {:error, changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")
      assert @throttled in errors_on(changeset).base

      # Being throttled is not a spend: the balance is exactly what the accepted
      # runs cost.
      assert CreditBalance.remaining(Ai.balance(buyer, granted.entitlement.id)) == 5 - max
    end

    test "a throttled attempt is logged, so the limiter can see its own refusals", %{
      granted: granted,
      buyer: buyer
    } do
      stub_gateway()
      max = max_runs()

      for _attempt <- 1..(max + 1) do
        Ai.complete(buyer, granted.entitlement.id, "hello")
      end

      statuses =
        granted.entitlement.id
        |> then(&Ai.recent_runs(buyer, &1, 10))
        |> Enum.map(& &1.status)

      assert :refused in statuses
    end

    test "the limit is per purchase, not per account", %{category: category, buyer: buyer} do
      stub_gateway()

      first =
        granted_entitlement_fixture(buyer, category, product_type: :ai, config: %{"credits" => 5})

      second =
        granted_entitlement_fixture(buyer, category, product_type: :ai, config: %{"credits" => 5})

      max = max_runs()

      for _attempt <- 1..max do
        assert {:ok, %Completion{}} = Ai.complete(buyer, first.entitlement.id, "hello")
      end

      # Saturating one pool must not throttle a different purchase by the same
      # buyer: a rate limit on the account would let one product deny another.
      assert {:ok, %Completion{}} = Ai.complete(buyer, second.entitlement.id, "hello")
    end
  end

  describe "the gateway registry" do
    test "the configured gateway is reported and available" do
      assert Ai.gateway_name() == :nexus
      assert Ai.available?()
    end

    test "a registered gateway with no API key is not available" do
      # Serial: it mutates the shared application env for the rest of the suite.
      original = Application.get_env(:cass, :nexus_ai)
      on_exit(fn -> Application.put_env(:cass, :nexus_ai, original) end)

      for missing <- [nil, "", "   "] do
        Application.put_env(:cass, :nexus_ai, Keyword.put(original, :api_key, missing))

        # Registration is not readiness: reporting this as available would offer
        # the buyer a button that only ever round-trips to a 401 and a refund.
        refute Ai.available?()
      end
    end

    test "a missing key refunds rather than raising inside the adapter" do
      original = Application.get_env(:cass, :nexus_ai)
      on_exit(fn -> Application.put_env(:cass, :nexus_ai, original) end)

      Application.put_env(:cass, :nexus_ai, Keyword.put(original, :api_key, nil))

      buyer = Scope.for_user(user_fixture())

      granted =
        granted_entitlement_fixture(buyer, category_fixture(),
          product_type: :ai,
          config: %{"credits" => 5}
        )

      assert {:error, changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")
      assert @refused in errors_on(changeset).base

      assert CreditBalance.remaining(Ai.balance(buyer, granted.entitlement.id)) == 5
    end

    test "a disabled gateway is indistinguishable from an unconfigured one" do
      # Serial: it mutates the shared application env for the rest of the suite.
      original = Application.get_env(:cass, Cass.Ai)
      on_exit(fn -> Application.put_env(:cass, Cass.Ai, original) end)

      Application.put_env(:cass, Cass.Ai,
        gateways: [nexus: [module: Cass.Ai.Gateways.Nexus, enabled: false]]
      )

      assert Cass.Ai.Gateways.enabled() == []
      assert Ai.gateway_name() == nil
      refute Ai.available?()
    end

    test "with no gateway a run is refused and refunded, not raised on", %{
      granted: granted,
      buyer: buyer
    } do
      original = Application.get_env(:cass, Cass.Ai)
      on_exit(fn -> Application.put_env(:cass, Cass.Ai, original) end)

      Application.put_env(:cass, Cass.Ai, gateways: [])

      assert {:error, changeset} = Ai.complete(buyer, granted.entitlement.id, "hello")
      assert @refused in errors_on(changeset).base
      assert CreditBalance.remaining(Ai.balance(buyer, granted.entitlement.id)) == 5
    end
  end

  describe "entitlement helpers" do
    test "granted_credits/1 only accepts a non-negative integer" do
      for config <- [%{}, %{"credits" => "5"}, %{"credits" => 5.0}, %{"credits" => -1}] do
        assert Ai.granted_credits(%Entitlement{metadata: config}) == 0
      end

      assert Ai.granted_credits(%Entitlement{metadata: %{"credits" => 7}}) == 7
      assert Ai.granted_credits(%Entitlement{metadata: nil}) == 0
    end

    test "model_for/1 only accepts a non-empty string" do
      assert Ai.model_for(%Entitlement{metadata: %{"model" => "fast"}}) == "fast"
      assert Ai.model_for(%Entitlement{metadata: %{"model" => ""}}) == nil
      assert Ai.model_for(%Entitlement{metadata: %{"model" => 5}}) == nil
      assert Ai.model_for(%Entitlement{metadata: %{}}) == nil
    end
  end
end
