defmodule Wail.Classrooms do
  @moduledoc """
  Public API for temporary, process-backed flight classrooms.
  """

  alias Wail.Classrooms.ClassroomServer
  alias Wail.Classrooms.Supervisor

  @alphabet "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  def create_room(instructor_id, opts \\ []) when is_binary(instructor_id) do
    room_id = opts |> Keyword.get_lazy(:room_id, &generate_room_id/0) |> normalize_room_id()
    server_opts = Keyword.merge(opts, room_id: room_id, instructor_id: instructor_id)

    case Supervisor.start_room(server_opts) do
      {:ok, pid} ->
        Phoenix.PubSub.broadcast(
          Wail.PubSub,
          lobby_topic(),
          {:classroom_listing_changed, room_id}
        )

        {:ok, %{room_id: room_id, pid: pid}}

      {:error, {:already_started, _pid}} ->
        {:error, :room_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def room_exists?(room_id), do: is_pid(whereis(room_id))

  def whereis(room_id) do
    room_id = normalize_room_id(room_id)

    case Registry.lookup(Wail.Classrooms.Registry, room_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  def snapshot(room_id), do: call_room(room_id, &ClassroomServer.snapshot/1)

  def listing(room_id), do: call_room(room_id, fn pid -> {:ok, ClassroomServer.listing(pid)} end)

  def list_active_lessons do
    Wail.Classrooms.Registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Task.async_stream(
      fn {_room_id, pid} ->
        try do
          ClassroomServer.listing(pid)
        catch
          :exit, _reason -> nil
        end
      end,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, listing} -> [listing]
      _other -> []
    end)
    |> Enum.sort_by(&{status_order(&1.status), String.downcase(&1.plan_name), &1.room_id})
  end

  def enroll(room_id, participant) do
    call_room(room_id, &ClassroomServer.enroll(&1, participant))
  end

  def configure_lesson(room_id, participant, attrs) do
    call_room(room_id, &ClassroomServer.configure_lesson(&1, participant, attrs))
  end

  def lesson_action(room_id, participant, action) do
    call_room(room_id, &ClassroomServer.lesson_action(&1, participant, action))
  end

  def flight_command(room_id, participant, command) do
    call_room(room_id, &ClassroomServer.flight_command(&1, participant, command))
  end

  def command(room_id, participant, command), do: flight_command(room_id, participant, command)

  def tick(room_id, elapsed_ms \\ 250),
    do: call_room(room_id, &ClassroomServer.tick(&1, elapsed_ms))

  def presence_changed(room_id, participant_count) when is_integer(participant_count) do
    case whereis(room_id) do
      nil -> :ok
      pid -> ClassroomServer.presence_changed(pid, participant_count)
    end
  end

  def topic(room_id), do: "classroom:#{normalize_room_id(room_id)}"
  def lobby_topic, do: "classrooms:lobby"

  def normalize_room_id(room_id) when is_binary(room_id) do
    room_id
    |> String.trim()
    |> String.upcase()
  end

  defp call_room(room_id, callback) do
    case whereis(room_id) do
      nil -> {:error, :room_not_found}
      pid -> callback.(pid)
    end
  end

  defp status_order(:waiting), do: 0
  defp status_order(:running), do: 1
  defp status_order(:paused), do: 2
  defp status_order(:completed), do: 3

  defp generate_room_id do
    suffix =
      for <<byte <- :crypto.strong_rand_bytes(6)>>, into: "" do
        binary_part(@alphabet, rem(byte, byte_size(@alphabet)), 1)
      end

    "SIM-#{suffix}"
  end
end
