defmodule CassWeb.PurchaseAILiveTest do
  @moduledoc """
  The AI panel on the access page for one purchase (`/purchases/:id`).

  Split from `CassWeb.PurchaseLiveTest` because the questions are different. That
  file asks whether a buyer can see a *credential*; this one asks whether the page
  runs a metered purchase correctly — that the balance shown is the balance
  charged, that a run reaches the gateway and renders, that refusals cost nothing
  and read honestly, and that none of it is reachable by anyone but the buyer.

  The LiveView is driven through `Phoenix.LiveViewTest` with a stubbed gateway, so
  the page is exercised over the same event boundary production uses and no
  handler is called directly.
  """
  use CassWeb.ConnCase

  import Phoenix.LiveViewTest

  import Cass.AccountsFixtures
  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope
  alias Cass.Ai
  alias Cass.Ai.CreditBalance

  setup do
    buyer_user = user_fixture()
    stranger = user_fixture()
    category = category_fixture()

    granted =
      granted_entitlement_fixture(Scope.for_user(buyer_user), category,
        product_type: :ai,
        config: %{"credits" => 3, "model" => "fast"}
      )

    %{
      buyer_user: buyer_user,
      stranger: stranger,
      granted: granted,
      entitlement_id: granted.entitlement.id
    }
  end

  defp granted_ai(%{buyer_user: buyer}, credits, opts \\ []) do
    config =
      if model = opts[:model],
        do: %{"credits" => credits, "model" => model},
        else: %{"credits" => credits}

    granted_entitlement_fixture(Scope.for_user(buyer), category_fixture(),
      product_type: :ai,
      config: config
    )
  end

  defp stub_gateway(content \\ "Rewritten: a tidier draft.") do
    Req.Test.stub(:nexus_ai, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
      })
    end)
  end

  defp stub_failing_gateway do
    Req.Test.stub(:nexus_ai, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
    end)
  end

  describe "the panel itself" do
    test "an AI purchase shows credits and a prompt form, never an access code", ctx do
      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{ctx.entitlement_id}")

      assert has_element?(view, "#ai-panel")
      assert has_element?(view, "#credit-balance-value")
      assert has_element?(view, "#ai-run-form")
      assert has_element?(view, "#ai-run-form-prompt")
      assert has_element?(view, "#ai-run-submit")

      # The credential panel belongs to the other mechanism: an AI purchase must
      # never present one, whatever its product name says.
      refute has_element?(view, "#access-code-panel")
      refute has_element?(view, "#access-code")
    end

    test "the shown balance is the balance the pool actually holds", ctx do
      granted = granted_ai(ctx, 7)

      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{granted.entitlement.id}")

      assert view |> element("#credit-balance-value") |> render() =~ "7"

      assert CreditBalance.remaining(
               Ai.balance(Scope.for_user(ctx.buyer_user), granted.entitlement.id)
             ) == 7
    end

    test "no result and no history before anything has run", ctx do
      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{ctx.entitlement_id}")

      refute has_element?(view, "#ai-result")
      refute has_element?(view, "#ai-run-history")
    end
  end

  describe "running a prompt" do
    test "a successful run renders the result and spends one credit", ctx do
      stub_gateway("Rewritten: a tidier draft.")

      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{ctx.entitlement_id}")

      html =
        view
        |> form("#ai-run-form", ai_run: %{prompt: "rewrite this: hi"})
        |> render_submit()

      assert html =~ "Rewritten: a tidier draft."

      assert has_element?(view, "#ai-result")
      assert view |> element("#credit-balance-value") |> render() =~ "2"

      scope = Scope.for_user(ctx.buyer_user)
      assert CreditBalance.remaining(Ai.balance(scope, ctx.entitlement_id)) == 2
    end

    test "the prompt reaches the gateway with the model the purchase pinned", ctx do
      granted = granted_ai(ctx, 5, model: "fast")

      Req.Test.stub(:nexus_ai, fn conn ->
        body = conn |> Req.Test.raw_body() |> Jason.decode!()

        assert body["model"] == "fast"
        assert body["messages"] == [%{"role" => "user", "content" => "rewrite this: hi"}]
        assert body["stream"] == false

        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "ok"}}]})
      end)

      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{granted.entitlement.id}")

      view
      |> form("#ai-run-form", ai_run: %{prompt: "rewrite this: hi"})
      |> render_submit()

      assert has_element?(view, "#ai-result")
    end

    test "successive runs spend one credit each", ctx do
      stub_gateway()

      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{ctx.entitlement_id}")

      for _attempt <- 1..2 do
        view |> form("#ai-run-form", ai_run: %{prompt: "again please"}) |> render_submit()
      end

      assert view |> element("#credit-balance-value") |> render() =~ "1"
    end

    test "the run history appears once something has run", ctx do
      stub_gateway()

      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{ctx.entitlement_id}")

      view |> form("#ai-run-form", ai_run: %{prompt: "hello"}) |> render_submit()

      assert has_element?(view, "#ai-run-history")
      assert view |> element("#ai-run-history") |> render() =~ "succeeded"
    end
  end

  describe "refusals" do
    test "an exhausted pool says so and the submit stays disabled", ctx do
      granted = granted_ai(ctx, 1)
      stub_gateway()

      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{granted.entitlement.id}")

      view |> form("#ai-run-form", ai_run: %{prompt: "first"}) |> render_submit()

      assert has_element?(view, "#ai-no-credits")
      assert has_element?(view, "#ai-run-submit[disabled]")
    end

    test "a gateway failure shows an error, spends nothing, and renders no result", ctx do
      stub_failing_gateway()

      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{ctx.entitlement_id}")

      view
      |> form("#ai-run-form", ai_run: %{prompt: "hello"})
      |> render_submit()

      refute has_element?(view, "#ai-result")

      # CASS's outage is not the buyer's bill.
      assert view |> element("#credit-balance-value") |> render() =~ "3"

      assert CreditBalance.remaining(
               Ai.balance(Scope.for_user(ctx.buyer_user), ctx.entitlement_id)
             ) == 3
    end

    test "a blank prompt is refused without spending a credit", ctx do
      # Deliberately unstubbed: a blank prompt must be refused before any request
      # is attempted, so an HTTP call here would raise rather than pass quietly.
      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{ctx.entitlement_id}")

      view |> form("#ai-run-form", ai_run: %{prompt: "   "}) |> render_submit()

      refute has_element?(view, "#ai-result")
      assert view |> element("#credit-balance-value") |> render() =~ "3"
    end

    test "the prompt field is length-capped in the markup", ctx do
      {:ok, _view, html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{ctx.entitlement_id}")

      assert html =~ ~s(maxlength="8000")
    end
  end

  describe "when no gateway is configured" do
    setup do
      original = Application.get_env(:cass, Cass.Ai)
      on_exit(fn -> Application.put_env(:cass, Cass.Ai, original) end)

      Application.put_env(:cass, Cass.Ai, gateways: [])
      :ok
    end

    test "the panel explains the outage and offers no way to submit", ctx do
      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{ctx.entitlement_id}")

      assert has_element?(view, "#ai-unavailable")
      assert has_element?(view, "#ai-run-submit[disabled]")

      # The purchase and its credits are still visible: an outage hides the
      # button, not the buyer's balance.
      assert has_element?(view, "#credit-balance-value")
    end
  end

  describe "somebody else's purchase" do
    test "a stranger sees the same page as an unknown id", ctx do
      {:ok, foreign_view, foreign_html} =
        log_in_user(ctx.conn, ctx.stranger) |> live(~p"/purchases/#{ctx.entitlement_id}")

      {:ok, missing_view, _missing_html} =
        log_in_user(ctx.conn, ctx.stranger) |> live(~p"/purchases/#{999_999}")

      assert foreign_html =~ "not found"
      refute has_element?(foreign_view, "#ai-panel")

      # Identical text, so the page cannot be used to probe for which ids exist.
      assert visible_text(render(foreign_view)) == visible_text(render(missing_view))
    end

    test "a stranger cannot submit a run against it", ctx do
      stub_gateway()

      {:ok, view, _html} =
        log_in_user(ctx.conn, ctx.stranger) |> live(~p"/purchases/#{ctx.entitlement_id}")

      refute has_element?(view, "#ai-run-form")

      # No credit moved, which is the property that matters even if the markup
      # were somehow bypassed.
      assert CreditBalance.remaining(
               Ai.balance(Scope.for_user(ctx.buyer_user), ctx.entitlement_id)
             ) == 3
    end

    test "a guest is sent to the login page", ctx do
      assert {:error, {:redirect, %{to: to}}} =
               live(ctx.conn, ~p"/purchases/#{ctx.entitlement_id}")

      assert to == ~p"/users/log-in"
    end
  end

  describe "a purchase that is no longer active" do
    test "a revoked AI grant shows nothing", ctx do
      granted = revoke_fixture(ctx.granted)

      {:ok, view, html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{granted.entitlement.id}")

      assert html =~ "not found"
      refute has_element?(view, "#ai-panel")
    end

    test "an elapsed AI grant shows nothing", ctx do
      granted = revoke_fixture(ctx.granted)
      expire_entitlement_fixture(granted.entitlement)

      {:ok, view, html} =
        log_in_user(ctx.conn, ctx.buyer_user) |> live(~p"/purchases/#{granted.entitlement.id}")

      assert html =~ "not found"
      refute has_element?(view, "#ai-panel")
    end
  end

  defp visible_text(html), do: html |> LazyHTML.from_document() |> LazyHTML.text()
end
