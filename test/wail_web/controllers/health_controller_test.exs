defmodule WailWeb.HealthControllerTest do
  use WailWeb.ConnCase, async: true

  test "GET /health reports that the web process is ready", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert response(conn, 200) == "ok"
  end
end
