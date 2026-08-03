defmodule Wail.ClassroomsTest do
  use ExUnit.Case, async: false

  alias Wail.Classrooms

  test "creates and looks up independent supervised rooms" do
    first_code = "SIM-CTX#{System.unique_integer([:positive])}"
    second_code = "SIM-CTX#{System.unique_integer([:positive])}"

    assert {:ok, first} =
             Classrooms.create_room("first-instructor",
               room_id: first_code,
               tick_interval: :manual
             )

    assert {:ok, second} =
             Classrooms.create_room("second-instructor",
               room_id: second_code,
               tick_interval: :manual
             )

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Wail.Classrooms.Supervisor, first.pid)
      DynamicSupervisor.terminate_child(Wail.Classrooms.Supervisor, second.pid)
    end)

    assert Classrooms.whereis(String.downcase(first_code)) == first.pid
    assert Classrooms.whereis(second_code) == second.pid
    assert first.pid != second.pid
  end

  test "rejects duplicate room IDs and missing-room calls" do
    room_code = "SIM-DUP#{System.unique_integer([:positive])}"

    assert {:ok, room} =
             Classrooms.create_room("instructor", room_id: room_code, tick_interval: :manual)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Wail.Classrooms.Supervisor, room.pid)
    end)

    assert Classrooms.create_room("other", room_id: room_code, tick_interval: :manual) ==
             {:error, :room_exists}

    assert Classrooms.snapshot("SIM-MISSING") == {:error, :room_not_found}
  end
end
