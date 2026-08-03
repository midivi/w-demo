defmodule WailWeb.PageController do
  use WailWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def health(conn, _params) do
    send_resp(conn, :ok, "ok")
  end
end
