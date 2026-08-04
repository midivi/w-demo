defmodule WailWeb.ClassroomLoadBenchTest do
  @moduledoc """
  Not a correctness test — a measurement harness for the 100-student scenario.
  Mounts N REAL student LiveViews plus the instructor and measures total BEAM
  CPU (all processes, all schedulers) for the join phase and for steady state.

      mix test test/wail_web/live/classroom_load_bench_test.exs --include bench
  """
  use WailWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Wail.Classrooms
  alias Wail.Classrooms.ClassroomServer
  alias WailWeb.ClassroomAccess

  @moduletag :bench
  @moduletag timeout: 900_000

  @n String.to_integer(System.get_env("N", "100"))

  # total CPU ms burned across every scheduler while `fun` runs, plus wall ms
  defp cpu(fun) do
    :erlang.statistics(:runtime)
    :erlang.statistics(:wall_clock)
    fun.()
    {_, cpu_ms} = :erlang.statistics(:runtime)
    {_, wall_ms} = :erlang.statistics(:wall_clock)
    {cpu_ms, wall_ms}
  end

  # Reductions across every process EXCEPT this test process. LiveViewTest's
  # render/render_click assemble full HTML in the caller, which a real browser
  # session never does, so counting the harness would flatter or punish designs
  # for the wrong reason. This counts only server-side work.
  defp server_reductions do
    me = self()

    Process.list()
    |> Enum.reject(&(&1 == me))
    |> Enum.reduce(0, fn pid, acc ->
      case Process.info(pid, :reductions) do
        {:reductions, r} -> acc + r
        nil -> acc
      end
    end)
  end

  defp measure(label, fun) do
    before = server_reductions()
    {cpu_ms, wall_ms} = cpu(fun)
    delta = server_reductions() - before
    {label, cpu_ms, wall_ms, delta}
  end

  defp drain(pids) do
    Enum.each(1..200, fn _ ->
      busy =
        Enum.any?(pids, fn p ->
          match?({:message_queue_len, n} when n > 0, Process.info(p, :message_queue_len))
        end)

      if busy, do: Process.sleep(10)
    end)
  end

  setup %{conn: conn} do
    room_id = "SIM-LB#{System.unique_integer([:positive])}"
    instructor_id = "instructor-bench"

    {:ok, room} =
      Classrooms.create_room(instructor_id,
        room_id: room_id,
        instructor_name: "Captain Noor",
        tick_interval: :manual,
        idle_timeout: :timer.minutes(5)
      )

    on_exit(fn ->
      if Process.alive?(room.pid),
        do: DynamicSupervisor.terminate_child(Wail.Classrooms.Supervisor, room.pid)
    end)

    token = ClassroomAccess.sign(room_id, instructor_id, "Captain Noor", :instructor)

    %{
      room: room,
      room_id: room_id,
      conn: init_test_session(conn, %{guest_id: instructor_id}),
      token: token,
      instructor_id: instructor_id
    }
  end

  test "prices the join storm and steady state with #{@n} real LiveViews", ctx do
    %{room: room, room_id: room_id, conn: conn, token: token} = ctx

    students =
      for i <- 1..@n do
        %{
          id: "student-#{i}",
          display_name: "Pilot #{String.pad_leading("#{i}", 3, "0")}",
          role: :student
        }
      end

    {:ok, iview, _} = live(conn, ~p"/rooms/#{room_id}?access=#{token}")
    _ = render(iview)

    IO.puts("\n\n======== #{@n}-STUDENT LOAD PROFILE (real LiveViews) ========\n")

    # ---- PHASE 1: 100 students join ----------------------------------------
    {_, join_cpu, join_wall, join_red} =
      measure(:join, fn ->
        views =
          for st <- students do
            t = ClassroomAccess.sign(room_id, st.id, st.display_name, :student)
            c = Phoenix.ConnTest.build_conn() |> init_test_session(%{guest_id: st.id})
            {:ok, v, _} = live(c, ~p"/rooms/#{room_id}?access=#{t}")
            v
          end

        drain([iview.pid | Enum.map(views, & &1.pid)])
        Process.put(:views, views)
      end)

    views = Process.get(:views)
    all_pids = [iview.pid | Enum.map(views, & &1.pid)]

    IO.puts("PHASE 1 — JOIN STORM (#{@n} students joining a room)")
    IO.puts("  total BEAM CPU: #{join_cpu} ms   wall: #{join_wall} ms")
    IO.puts("  => #{Float.round(join_cpu / @n, 1)} ms of CPU per student joining")
    IO.puts("  => on a 2-core box that is #{Float.round(join_cpu / 2, 0)} ms of saturated wall time")
    IO.puts("  server-side reductions: #{join_red}")

    # ---- PHASE 2: steady state ---------------------------------------------
    {:ok, _} =
      ClassroomServer.lesson_action(room.pid, %{id: ctx.instructor_id, role: :instructor}, :start)

    drain(all_pids)

    simulated_seconds = 10

    {_, run_cpu, run_wall, run_red} =
      measure(:steady, fn ->
        # 4 ticks of 250 ms = 1 s of lesson = 1 broadcast round
        Enum.each(1..(simulated_seconds * 4), fn _ -> ClassroomServer.tick(room.pid, 250) end)
        drain(all_pids)
      end)

    IO.puts("\nPHASE 2 — STEADY STATE (lesson running, #{simulated_seconds} simulated seconds)")
    IO.puts("  total BEAM CPU: #{run_cpu} ms   wall: #{run_wall} ms")

    IO.puts("  server-side reductions: #{run_red}  (#{div(run_red, simulated_seconds)} per lesson-second)")
    per_sec = run_cpu / simulated_seconds
    IO.puts("  => #{Float.round(per_sec, 0)} ms of CPU per 1 second of lesson")

    IO.puts(
      "  => #{Float.round(per_sec / 1000 * 100, 0)}% of one core, " <>
        "#{Float.round(per_sec / 2000 * 100, 0)}% of the 2-core Fly machine"
    )

    # ---- PHASE 3: students actually flying ---------------------------------
    # every student presses a control twice per simulated second
    {_, fly_cpu, _, fly_red} =
      measure(:flying, fn ->
        Enum.each(1..(simulated_seconds * 4), fn tick ->
          if rem(tick, 2) == 0 do
            Enum.each(views, fn v ->
              render_click(v, "flight_command", %{"command" => "throttle_up"})
            end)
          end

          ClassroomServer.tick(room.pid, 250)
        end)

        drain(all_pids)
      end)

    IO.puts("  server-side reductions: #{fly_red}  (#{div(fly_red, simulated_seconds)} per lesson-second)")
    fly_per_sec = fly_cpu / simulated_seconds
    IO.puts("\nPHASE 3 — STEADY STATE + every student flying (2 clicks/sec each)")
    IO.puts("  total BEAM CPU: #{fly_cpu} ms")
    IO.puts("  => #{Float.round(fly_per_sec, 0)} ms of CPU per 1 second of lesson")

    IO.puts(
      "  => #{Float.round(fly_per_sec / 1000 * 100, 0)}% of one core, " <>
        "#{Float.round(fly_per_sec / 2000 * 100, 0)}% of the 2-core Fly machine"
    )

    # ---- where is it going? ------------------------------------------------
    {:reductions, ired} = Process.info(iview.pid, :reductions)
    {:reductions, sred} = Process.info(hd(views).pid, :reductions)
    {:reductions, rred} = Process.info(room.pid, :reductions)

    IO.puts("\nREDUCTIONS (proxy for CPU) accumulated per process:")
    IO.puts("  instructor LiveView : #{ired}")
    IO.puts("  ONE student LiveView: #{sred}   (x#{@n} = #{sred * @n})")
    IO.puts("  classroom GenServer : #{rred}")

    total = ired + sred * @n + rred

    IO.puts("\n  share of total: instructor #{Float.round(ired / total * 100, 1)}% | " <>
              "all students #{Float.round(sred * @n / total * 100, 1)}% | " <>
              "room server #{Float.round(rred / total * 100, 1)}%")

    IO.puts("")
  end
end
