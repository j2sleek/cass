defmodule CassWeb.Api.V1.HealthControllerTest do
  use CassWeb.ConnCase

  test "GET /api/v1/health returns a 200 with database status when the app is healthy" do
    conn = get(build_conn(), ~p"/api/v1/health")

    assert response_content_type(conn, :json) =~ "application/json"

    body = json_response(conn, 200)

    assert body["status"] == "ok"
    assert body["service"] == "cass"
    assert is_binary(body["version"])
    assert body["environment"] == "test"
    assert body["database"]["status"] == "up"
    assert is_integer(body["uptime_seconds"])
    assert body["uptime_seconds"] >= 0
    assert body["timestamp"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
  end

  test "GET /api/v1/health exposes no connection details" do
    conn = get(build_conn(), ~p"/api/v1/health")
    body_text = response(conn, 200)

    refute body_text =~ "postgres"
    refute body_text =~ "password"
    refute body_text =~ "hostname"
    refute body_text =~ "username"
    refute body_text =~ "5432"
  end
end
