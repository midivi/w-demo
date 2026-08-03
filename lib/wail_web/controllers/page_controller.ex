defmodule WailWeb.PageController do
  use WailWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
