defmodule CassWeb.InsightsLiveTest do
  use CassWeb.ConnCase

  import Cass.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Cass.Analytics

  describe "authorization" do
    test "redirects a guest to the login page" do
      assert {:error, {:redirect, %{to: to}}} = live(build_conn(), ~p"/insights")
      assert to =~ "/users/log-in"
    end

    test "redirects a signed-in non-admin away" do
      conn = log_in_user(build_conn(), user_fixture())

      assert {:error, {:redirect, _}} = live(conn, ~p"/insights")
    end

    test "an admin sees the dashboard" do
      conn = log_in_user(build_conn(), admin_fixture())

      {:ok, view, _html} = live(conn, ~p"/insights")

      assert has_element?(view, "h1", "Insights")
      assert has_element?(view, "#insights-window-7")
      assert has_element?(view, "#insights-window-30")
      assert has_element?(view, "#product-ideas")
    end
  end

  describe "data" do
    setup do
      %{conn: log_in_user(build_conn(), admin_fixture())}
    end

    test "shows traffic, funnel, and top pages", %{conn: conn} do
      :ok = Analytics.track("page_view", %{path: "/catalog", visitor_id: "v1"})
      :ok = Analytics.track("product_view", %{subject_id: 1, metadata: %{title: "Alpha"}})
      :ok = Analytics.track("order_created")
      :ok = Analytics.track("order_paid")

      {:ok, view, _html} = live(conn, ~p"/insights")

      assert has_element?(view, "h1", "Insights")
      assert render(view) =~ "Purchase funnel"
      assert render(view) =~ "/catalog"
      assert render(view) =~ "Alpha"
    end

    test "surfaces empty searches as product ideas", %{conn: conn} do
      :ok = Analytics.track("search", %{metadata: %{query: "nft art", result_count: 0}})

      {:ok, view, _html} = live(conn, ~p"/insights")

      assert render(view) =~ "nft art"
    end

    test "accepts a window query parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/insights?days=7")
      assert has_element?(view, "h1", "Insights")

      {:ok, view, _html} = live(conn, ~p"/insights?days=90")
      assert has_element?(view, "h1", "Insights")
    end
  end
end
