defmodule WailWeb.JoinCostTest do
  use WailWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Wail.Classrooms
  alias WailWeb.{ClassroomAccess, ClassroomPresence}

  @moduletag :bench
  @moduletag timeout: 600_000

  defp server_reductions do
    me = self()
    Process.list()
    |> Enum.reject(&(&1 == me))
    |> Enum.reduce(0, fn p, acc ->
      case Process.info(p, :reductions) do
        {:reductions, r} -> acc + r
        nil -> acc
      end
    end)
  end

  test "cost of ONE join as the room fills" do
    IO.puts("\n=== what does one student joining cost, by room size? ===\n")
    IO.puts(String.pad_trailing("roster", 10) <> String.pad_trailing("1 mount (reductions)", 24) <>
            String.pad_trailing("Presence.list", 18) <> "diff fan-out")

    for k <- [0, 25, 50, 100] do
      room_id = "SIM-JC#{System.unique_integer([:positive])}"
      iid = "instr-#{k}"
      {:ok, _room} = Classrooms.create_room(iid, room_id: room_id, instructor_name: "Cap", tick_interval: :manual)
      topic = Classrooms.topic(room_id)

      # k already-present students: real presences + real subscribers, no LiveView
      me = self()
      holders =
        for i <- 1..max(k, 1)//1, k > 0 do
          pid = spawn(fn ->
            Phoenix.PubSub.subscribe(Wail.PubSub, topic)
            {:ok, _} = ClassroomPresence.track(self(), topic, "student-#{i}", %{
              id: "student-#{i}", name: "Pilot #{i}", role: :student, joined_at: DateTime.utc_now()})
            send(me, {:ok, self()})
            Process.sleep(:infinity)
          end)
          receive do: ({:ok, ^pid} -> :ok)
          {:ok, _} = Classrooms.enroll(room_id, %{id: "student-#{i}", display_name: "Pilot #{i}", role: :student})
          pid
        end

      Process.sleep(100)

      # isolated cost of Presence.list at this roster size
      {list_us, _} = :timer.tc(fn -> Enum.each(1..50, fn _ -> ClassroomPresence.list(topic) end) end)

      # cost of ONE more student mounting a real LiveView
      newbie = %{id: "newcomer", display_name: "New Pilot", role: :student}
      {:ok, _} = Classrooms.enroll(room_id, newbie)
      tok = ClassroomAccess.sign(room_id, newbie.id, newbie.display_name, :student)
      c = Phoenix.ConnTest.build_conn() |> init_test_session(%{guest_id: newbie.id})

      before = server_reductions()
      {:ok, v, _} = live(c, ~p"/rooms/#{room_id}?access=#{tok}")
      _ = render(v)
      Process.sleep(50)
      mount_red = server_reductions() - before

      # of that, how much landed in the k existing subscribers (the fan-out)?
      fanout =
        Enum.reduce(holders, 0, fn p, acc ->
          case Process.info(p, :reductions) do
            {:reductions, r} -> acc + r
            nil -> acc
          end
        end)

      IO.puts(
        String.pad_trailing("#{k}", 10) <>
        String.pad_trailing("#{mount_red}", 24) <>
        String.pad_trailing("#{Float.round(list_us / 50, 1)} us", 18) <>
        "#{fanout}"
      )

      Enum.each(holders, &Process.exit(&1, :kill))
    end
  end
end
