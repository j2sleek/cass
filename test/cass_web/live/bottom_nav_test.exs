defmodule CassWeb.BottomNavTest do
  @moduledoc """
  The mobile bottom tab bar (`Layouts.bottom_nav`).

  Coverage focuses on which tabs exist for guests vs. signed-in accounts, the
  `aria-current="page"` active state, and that detail pages keep their section
  tab highlighted. Touch-target sizing (`h-14`) is class-level and asserted by
  the e2e viewport matrix rather than here.
  """
  use CassWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Cass.Catalog

  test "a guest sees the guest tabs with the current section highlighted" do
    {:ok, view, _html} = live(build_conn(), "/catalog")

    assert has_element?(view, "nav[aria-label='Primary mobile']")
    assert has_element?(view, "#tab-home")
    assert has_element?(view, "#tab-catalog")
    assert has_element?(view, "#tab-login")
    assert has_element?(view, "#tab-register")

    refute has_element?(view, "#tab-orders")
    refute has_element?(view, "#tab-settings")

    assert element(view, "#tab-catalog") |> render() =~ ~s(aria-current="page")
    refute element(view, "#tab-home") |> render() =~ "aria-current"
  end

  test "a signed-in account sees the account tabs with the current section highlighted",
       %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})
    {:ok, view, _html} = live(conn, "/orders")

    assert has_element?(view, "#tab-home")
    assert has_element?(view, "#tab-catalog")
    assert has_element?(view, "#tab-orders")
    assert has_element?(view, "#tab-settings")

    refute has_element?(view, "#tab-login")
    refute has_element?(view, "#tab-register")

    assert element(view, "#tab-orders") |> render() =~ ~s(aria-current="page")
    refute element(view, "#tab-catalog") |> render() =~ "aria-current"
  end

  test "a detail page keeps its section tab highlighted", %{conn: conn} do
    {:ok, _category} = Catalog.create_category(%{name: "Digital", slug: "digital"})

    {:ok, view, _html} = live(conn, "/catalog/categories/digital")

    assert has_element?(view, "#tab-catalog")
    assert element(view, "#tab-catalog") |> render() =~ ~s(aria-current="page")
  end

  test "the storefront home renders the bottom bar for guests" do
    conn = get(build_conn(), ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(aria-label="Primary mobile")
    assert html =~ ~s(id="tab-home")
    assert html =~ ~s(id="tab-catalog")
    assert html =~ ~s(id="tab-login")
    assert html =~ ~s(id="tab-register")
  end
end
