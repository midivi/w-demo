defmodule Wail.Classrooms.ClassroomServerTest do
  use ExUnit.Case, async: true

  alias Wail.Classrooms.ClassroomServer

  setup do
    room_id = "SIM-#{System.unique_integer([:positive])}"
    instructor = %{id: "guest-instructor", display_name: "Captain Noor", role: :instructor}

    server =
      start_supervised!(
        {ClassroomServer,
         room_id: room_id,
         instructor_id: instructor.id,
         instructor_name: instructor.display_name,
         tick_interval: :manual,
         idle_timeout: :timer.minutes(1)}
      )

    %{server: server, room_id: room_id, instructor: instructor}
  end

  test "returns an initial joinable lesson listing", %{server: server, room_id: room_id} do
    assert {:ok, snapshot} = ClassroomServer.snapshot(server)
    assert snapshot.room_id == room_id
    assert snapshot.status == :waiting
    assert snapshot.joinable?
    assert snapshot.students == []
    assert snapshot.plan.id == :basic_controls

    listing = ClassroomServer.listing(server)
    assert listing.instructor_name == "Captain Noor"
    assert listing.joinable?
  end

  test "owns an independent aircraft for each enrolled student", context do
    %{server: server, instructor: instructor} = context
    first = student("student-1", "Sam")
    second = student("student-2", "Alex")

    assert {:ok, _snapshot} = ClassroomServer.enroll(server, first)
    assert {:ok, _snapshot} = ClassroomServer.enroll(server, second)
    assert {:ok, _snapshot} = ClassroomServer.lesson_action(server, instructor, :start)

    assert {:ok, student_snapshot} =
             ClassroomServer.flight_command(server, first, {:adjust, :throttle, 10})

    assert Enum.map(student_snapshot.students, & &1.id) == [first.id]

    assert {:ok, snapshot} = ClassroomServer.snapshot(server)
    assert student_snapshot(snapshot, first.id).flight.throttle_percent == 65
    assert student_snapshot(snapshot, second.id).flight.throttle_percent == 55

    assert ClassroomServer.flight_command(server, instructor, {:adjust, :bank, 3}) ==
             {:error, :forbidden}
  end

  test "students progress and score independently", context do
    %{server: server, instructor: instructor} = context
    first = student("student-1", "Sam")
    second = student("student-2", "Alex")

    {:ok, _snapshot} = ClassroomServer.enroll(server, first)
    {:ok, _snapshot} = ClassroomServer.enroll(server, second)
    {:ok, _snapshot} = ClassroomServer.lesson_action(server, instructor, :start)
    {:ok, _snapshot} = ClassroomServer.flight_command(server, first, {:adjust, :throttle, 10})

    assert {:ok, snapshot} = ClassroomServer.tick(server, 2_000)
    assert student_snapshot(snapshot, first.id).score == 1
    assert student_snapshot(snapshot, first.id).command_index == 1
    assert student_snapshot(snapshot, second.id).score == 0
    assert student_snapshot(snapshot, second.id).command_index == 0
  end

  test "closes enrollment at start but permits an enrolled reconnect", context do
    %{server: server, instructor: instructor} = context
    enrolled = student("student-1", "Sam")

    assert {:ok, _snapshot} = ClassroomServer.enroll(server, enrolled)
    assert {:ok, _snapshot} = ClassroomServer.lesson_action(server, instructor, :start)
    assert {:ok, _snapshot} = ClassroomServer.enroll(server, enrolled)

    assert ClassroomServer.enroll(server, student("late", "Late Pilot")) ==
             {:error, :lesson_not_joinable}
  end

  test "three expired attempts penalize the command once", context do
    %{server: server, instructor: instructor} = context
    student = student("student-1", "Sam")

    {:ok, _snapshot} = ClassroomServer.enroll(server, student)

    assert {:ok, _snapshot} =
             ClassroomServer.configure_lesson(server, instructor, %{
               attempt_duration_seconds: 5,
               maximum_attempts: 3
             })

    {:ok, _snapshot} = ClassroomServer.lesson_action(server, instructor, :start)

    assert {:ok, snapshot} = ClassroomServer.tick(server, 5_000)
    assert student_snapshot(snapshot, student.id).attempt == 2
    assert student_snapshot(snapshot, student.id).score == 0

    {:ok, _snapshot} = ClassroomServer.tick(server, 5_000)
    assert {:ok, snapshot} = ClassroomServer.tick(server, 5_000)
    assert student_snapshot(snapshot, student.id).score == -1
    assert student_snapshot(snapshot, student.id).command_index == 1
  end

  test "completes the classroom after every enrolled student finishes", context do
    %{server: server, instructor: instructor} = context
    student = student("student-1", "Sam")

    {:ok, _snapshot} = ClassroomServer.enroll(server, student)

    {:ok, _snapshot} =
      ClassroomServer.configure_lesson(server, instructor, %{
        attempt_duration_seconds: 5,
        maximum_attempts: 1
      })

    {:ok, _snapshot} = ClassroomServer.lesson_action(server, instructor, :start)

    snapshot =
      Enum.reduce(1..4, nil, fn _command, _snapshot ->
        {:ok, snapshot} = ClassroomServer.tick(server, 5_000)
        snapshot
      end)

    assert snapshot.status == :completed
    assert student_snapshot(snapshot, student.id).completed?
    assert student_snapshot(snapshot, student.id).score == -2
  end

  test "pause freezes ATC timing while flight continues, and reset clears progress", context do
    %{server: server, instructor: instructor} = context
    student = student("student-1", "Sam")

    {:ok, _snapshot} = ClassroomServer.enroll(server, student)
    {:ok, running} = ClassroomServer.lesson_action(server, instructor, :start)
    before = student_snapshot(running, student.id)

    {:ok, _paused} = ClassroomServer.lesson_action(server, instructor, :pause)
    {:ok, after_tick} = ClassroomServer.tick(server, 1_000)
    paused_student = student_snapshot(after_tick, student.id)

    assert paused_student.attempt_remaining_ms == before.attempt_remaining_ms
    assert paused_student.flight.elapsed_seconds > before.flight.elapsed_seconds

    {:ok, _running} = ClassroomServer.lesson_action(server, instructor, :continue)
    {:ok, reset} = ClassroomServer.lesson_action(server, instructor, :reset)
    reset_student = student_snapshot(reset, student.id)

    assert reset.status == :waiting
    assert reset_student.score == 0
    assert reset_student.flight.altitude_ft == 2_400
    assert reset_student.transcript == []
  end

  test "rejects invalid instructor actions and configuration", context do
    %{server: server, instructor: instructor} = context
    intruder = %{instructor | id: "intruder"}

    assert ClassroomServer.lesson_action(server, instructor, :start) == {:error, :no_students}
    assert ClassroomServer.lesson_action(server, intruder, :pause) == {:error, :forbidden}

    assert ClassroomServer.configure_lesson(server, instructor, %{
             attempt_duration_seconds: 2,
             maximum_attempts: 20
           }) == {:error, :invalid_lesson_config}
  end

  test "empty rooms stop after their idle timeout" do
    room_id = "SIM-IDLE-#{System.unique_integer([:positive])}"

    server =
      start_supervised!(
        {ClassroomServer,
         room_id: room_id,
         instructor_id: "idle-instructor",
         tick_interval: :manual,
         idle_timeout: 20}
      )

    monitor_ref = Process.monitor(server)
    assert_receive {:DOWN, ^monitor_ref, :process, ^server, :normal}, 200
  end

  test "an active presence cancels idle shutdown" do
    room_id = "SIM-ACTIVE-#{System.unique_integer([:positive])}"

    server =
      start_supervised!(
        {ClassroomServer,
         room_id: room_id,
         instructor_id: "active-instructor",
         tick_interval: :manual,
         idle_timeout: 20}
      )

    ClassroomServer.presence_changed(server, 1)
    _state = :sys.get_state(server)
    monitor_ref = Process.monitor(server)
    refute_receive {:DOWN, ^monitor_ref, :process, ^server, _reason}, 50

    ClassroomServer.presence_changed(server, 0)
    assert_receive {:DOWN, ^monitor_ref, :process, ^server, :normal}, 200
  end

  test "automatic ticks only run during active lessons and throttle broadcasts", context do
    %{server: server, room_id: room_id, instructor: instructor} = context
    student = student("student-timer", "Timer Pilot")

    server_state = :sys.get_state(server)
    assert server_state.tick_timer == nil

    {:ok, automatic_server} =
      start_supervised(
        {ClassroomServer,
         room_id: "#{room_id}-AUTO",
         instructor_id: instructor.id,
         instructor_name: instructor.display_name,
         tick_interval: 60_000,
         broadcast_interval: 10_000,
         idle_timeout: :timer.minutes(1)},
        id: :automatic_classroom_server
      )

    automatic_room_id = "#{room_id}-AUTO"

    Phoenix.PubSub.subscribe(
      Wail.PubSub,
      Wail.Classrooms.updates_topic(automatic_room_id, instructor)
    )

    {:ok, _snapshot} = ClassroomServer.enroll(automatic_server, student)
    assert_receive {:classroom_updated, %{status: :waiting}}
    {:ok, _snapshot} = ClassroomServer.lesson_action(automatic_server, instructor, :start)
    assert_receive {:classroom_updated, %{status: :running}}

    %{tick_timer: {_timer_ref, tick_token}} = :sys.get_state(automatic_server)
    send(automatic_server, {:tick, tick_token})
    _state = :sys.get_state(automatic_server)
    refute_receive {:classroom_updated, _snapshot}, 20

    {:ok, _snapshot} = ClassroomServer.lesson_action(automatic_server, instructor, :reset)
    assert_receive {:classroom_updated, %{status: :waiting}}
    assert :sys.get_state(automatic_server).tick_timer == nil
  end

  test "student payloads stay compact as enrollment grows", %{server: server} do
    students =
      Enum.map(1..100, fn index ->
        student("student-#{index}", "Pilot #{index}")
      end)

    Enum.each(students, fn participant ->
      assert {:ok, %{students: [_student]}} = ClassroomServer.enroll(server, participant)
    end)

    last_student = List.last(students)
    assert {:ok, student_snapshot} = ClassroomServer.enroll(server, last_student)
    assert {:ok, instructor_snapshot} = ClassroomServer.snapshot(server)

    assert Enum.map(student_snapshot.students, & &1.id) == [last_student.id]
    assert length(student_snapshot.leaderboard) == 100
    refute Map.has_key?(List.first(student_snapshot.leaderboard), :flight)
    refute Map.has_key?(List.first(student_snapshot.leaderboard), :results)

    assert :erlang.external_size(student_snapshot) <
             div(:erlang.external_size(instructor_snapshot), 2)
  end

  defp student(id, name), do: %{id: id, display_name: name, role: :student}
  defp student_snapshot(snapshot, id), do: Enum.find(snapshot.students, &(&1.id == id))
end
