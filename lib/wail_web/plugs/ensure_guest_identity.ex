defmodule WailWeb.Plugs.EnsureGuestIdentity do
  @moduledoc "Assigns a stable, anonymous demo identity to the browser session."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :guest_id) do
      guest_id when is_binary(guest_id) -> conn
      _other -> put_session(conn, :guest_id, generate_guest_id())
    end
  end

  defp generate_guest_id do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
