defmodule CassWeb.PurchaseLiveTest do
  @moduledoc """
  The access page for one purchase (`/purchases/:id`).

  This page is the whole user-visible surface of the Delivery & Access
  boundary, so these tests are really about one question: **can the buyer see
  the delivery of a purchase they actually hold, and can anyone learn anything
  about a purchase they do not?**

  They drive it over HTTP with a real session token, because the property being
  defended is that identity comes from the session and never from the URL — so
  each test logs in as a *named* person rather than relying on a blanket
  "logged in" setup that would hide whose session was in play.
  """
  use CassWeb.ConnCase

  import Phoenix.LiveViewTest

  import Cass.CommerceFixtures

  alias Cass.Accounts.Scope

  @code_format ~r/^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/
  # Unanchored, because it searches rendered HTML rather than matching a value.
  @code_pattern ~r/[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}/

  setup do
    buyer_user = user_fixture()
    stranger = user_fixture()
    category = category_fixture()

    granted = granted_entitlement_fixture(Scope.for_user(buyer_user), category)

    %{
      buyer_user: buyer_user,
      stranger: stranger,
      granted: granted,
      entitlement: granted.entitlement
    }
  end

  describe "the buyer's own purchase" do
    test "shows the delivery for a paid, fulfilled purchase", %{
      conn: conn,
      buyer_user: buyer,
      entitlement: entitlement
    } do
      {:ok, _view, html} = log_in_user(conn, buyer) |> live(~p"/purchases/#{entitlement.id}")

      assert html =~ entitlement.product_name
      assert html =~ "Your access code"
      assert code(html) =~ @code_format
      assert html =~ "Access code"
      assert html =~ "Delivered"
    end

    test "shows a code in the documented shape", %{
      conn: conn,
      buyer_user: buyer,
      entitlement: entitlement
    } do
      {:ok, view, html} = log_in_user(conn, buyer) |> live(~p"/purchases/#{entitlement.id}")

      assert view |> element("#access-code") |> has_element?()
      assert code(html) =~ @code_format
    end

    test "the same code is shown on every visit", %{
      conn: conn,
      buyer_user: buyer,
      entitlement: entitlement
    } do
      conn = log_in_user(conn, buyer)
      {:ok, _view, first} = live(conn, ~p"/purchases/#{entitlement.id}")

      # A second, independent mount presents the same derived value.
      {:ok, _again, second} = live(conn, ~p"/purchases/#{entitlement.id}")

      assert code(first) == code(second)
    end

    test "shows the purchase snapshot, not the internal grant", %{
      conn: conn,
      buyer_user: buyer,
      entitlement: entitlement
    } do
      {:ok, _view, html} = log_in_user(conn, buyer) |> live(~p"/purchases/#{entitlement.id}")

      assert html =~ entitlement.variant_name
      assert html =~ "SKU"
      assert html =~ "Does not expire"

      # The page renders the narrowed access capability, so none of the
      # entitlement's internal identifiers reach the browser.
      refute html =~ "user_id"
      refute html =~ "order_item"
    end

    test "is reachable from the buyer's order page", %{
      conn: conn,
      buyer_user: buyer,
      granted: granted
    } do
      [order_item] = granted.order.order_items

      {:ok, view, _html} = log_in_user(conn, buyer) |> live(~p"/orders/#{granted.order.id}")

      # The order page links only the lines the delivery context reports as
      # exercisable, so a buyer can find their access without a dashboard.
      assert view |> element("#order-item-access-#{order_item.id}") |> has_element?()
    end
  end

  describe "somebody else's purchase" do
    test "a stranger sees the shared not-found page, not the delivery", %{
      conn: conn,
      stranger: stranger,
      entitlement: entitlement
    } do
      {:ok, _view, html} = log_in_user(conn, stranger) |> live(~p"/purchases/#{entitlement.id}")

      assert html =~ "not found"
      refute html =~ "Your access code"
      refute html =~ entitlement.product_name
    end

    test "an id that does not exist is indistinguishable from a foreign one", %{
      conn: conn,
      stranger: stranger,
      entitlement: entitlement
    } do
      conn = log_in_user(conn, stranger)

      {:ok, foreign_view, _html} = live(conn, ~p"/purchases/#{entitlement.id}")
      {:ok, missing_view, _html} = live(conn, ~p"/purchases/999_999_999")

      # A probe cannot tell "no such purchase" from "not yours", let alone learn
      # whose it was: the two pages are identical, not merely similar. The
      # comparison is on the visible text, since the surrounding markup carries
      # a fresh mount id and session token on every request.
      assert visible_text(render(foreign_view)) == visible_text(render(missing_view))
    end
  end

  describe "a purchase that is no longer active" do
    test "a revoked grant is not shown", %{conn: conn, buyer_user: buyer, granted: granted} do
      granted = revoke_fixture(granted)

      {:ok, _view, html} =
        log_in_user(conn, buyer) |> live(~p"/purchases/#{granted.entitlement.id}")

      assert html =~ "not found"
      refute html =~ "Your access code"
    end

    test "a guest is sent to the login page", %{conn: conn, entitlement: entitlement} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/purchases/#{entitlement.id}")
      assert to == ~p"/users/log-in"
    end
  end

  describe "a delivery kind with no mechanism yet" do
    test "an SMM purchase has nothing to exercise yet", %{conn: conn, buyer_user: buyer} do
      granted =
        granted_entitlement_fixture(Scope.for_user(buyer), category_fixture(), product_type: :smm)

      {:ok, _view, html} =
        log_in_user(conn, buyer) |> live(~p"/purchases/#{granted.entitlement.id}")

      # The kind is known, but this milestone has no way to hand it over, so the
      # page shows the same not-found state rather than an empty panel.
      assert html =~ "not found"
      refute html =~ "Your access code"
    end

    test "an SMM purchase gets no link from the order page", %{
      conn: conn,
      buyer_user: buyer
    } do
      granted =
        granted_entitlement_fixture(Scope.for_user(buyer), category_fixture(), product_type: :smm)

      [order_item] = granted.order.order_items

      {:ok, view, _html} = log_in_user(conn, buyer) |> live(~p"/orders/#{granted.order.id}")

      refute view |> element("#order-item-access-#{order_item.id}") |> has_element?()
    end
  end

  # The text a buyer actually sees, with the per-request markup that differs on
  # every mount (ids, session tokens) left out of the comparison.
  defp visible_text(html), do: html |> LazyHTML.from_document() |> LazyHTML.text()

  # The code as the buyer sees it, pulled straight out of the rendered panel.
  defp code(html) do
    case Regex.run(@code_pattern, html) do
      [matched] -> matched
      nil -> nil
    end
  end
end
