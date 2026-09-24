defmodule CassWeb.PageControllerTest do
  use CassWeb.ConnCase

  test "GET / renders the storefront shell", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "CASS"
    assert html =~ "One marketplace for"
    assert html =~ "Browse categories"
    assert html =~ "Digital products"
    assert html =~ "Social marketing services"
    assert html =~ "AI tools"
    assert html =~ "id=\"categories\""
    assert html =~ "© 2026 CASS Marketplace"
  end

  test "GET / includes SEO metadata", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s{data-default="CASS · Unified Marketplace"}
    assert html =~ ~s{name="description"}
    assert html =~ ~s{rel="canonical"}
    assert html =~ ~s{name="robots" content="index, follow"}
    assert html =~ ~s{property="og:type" content="website"}
    assert html =~ ~s{name="twitter:card" content="summary"}
    assert html =~ ~s{type="application/ld+json"}
  end
end
