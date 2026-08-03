defmodule WailWeb.ClassroomPresence do
  @moduledoc "Tracks the connected roster for each temporary classroom."

  use Phoenix.Presence,
    otp_app: :wail,
    pubsub_server: Wail.PubSub

  alias Wail.Classrooms

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_metas("classroom:" <> room_id, _diff, presences, state) do
    Classrooms.presence_changed(room_id, map_size(presences))
    {:ok, state}
  end

  def handle_metas(_topic, _diff, _presences, state), do: {:ok, state}
end
