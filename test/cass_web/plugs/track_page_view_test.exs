defmodule CassWeb.Plugs.TrackPageViewTest do
  use CassWeb.ConnCase, async: true

  import Cass.AccountsFixtures

  alias Cass.Analytics

  describe "call/2" do
    test "records one page_view for an HTML GET", %{conn: conn} do
      get(conn, ~p"/")

      assert [event] = Analytics.list_events(name: "page_view")
      assert event.path == "/"
      assert event.name == "page_view"
      assert is_binary(event.visitor_id)
    end

    test "reuses the visitor id across requests", %{conn: conn} do
      get(conn, ~p"/")
      visitor_id = Analytics.list_events(name: "page_view") |> hd() |> Map.fetch!(:visitor_id)

      conn = build_conn() |> init_test_session(%{cass_visitor_id: visitor_id})
      get(conn, ~p"/catalog")

      events = Analytics.list_events(name: "page_view")
      assert Enum.count(events) == 2
      assert Enum.all?(events, &(&1.visitor_id == visitor_id))
    end

    test "attributes the event to the signed-in user", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      get(conn, ~p"/")

      assert [event] = Analytics.list_events(name: "page_view")
      assert event.user_id == user.id
    end

    test "does not record non-GET requests", %{conn: conn} do
      post(conn, ~p"/users/log-in", %{
        "user" => %{"email" => "x@example.com", "password" => "nope"}
      })

      assert Analytics.list_events(name: "page_view") == []
    end
  end
end
