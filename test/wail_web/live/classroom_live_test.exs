defmodule WailWeb.ClassroomLiveTest do
  use WailWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Wail.Classrooms
  alias WailWeb.ClassroomAccess

  setup %{conn: conn} do
    room_id = "SIM-LV#{System.unique_integer([:positive])}"
    instructor_id = "instructor-browser"

    {:ok, room} =
      Classrooms.create_room(instructor_id,
        room_id: room_id,
        instructor_name: "Captain Noor",
        tick_interval: :manual,
        idle_timeout: :timer.minutes(1)
      )

    on_exit(fn ->
      if Process.alive?(room.pid) do
        DynamicSupervisor.terminate_child(Wail.Classrooms.Supervisor, room.pid)
      end
    end)

    instructor_token =
      ClassroomAccess.sign(room_id, instructor_id, "Captain Noor", :instructor)

    instructor_conn = init_test_session(conn, %{guest_id: instructor_id})

    %{
      room: room,
      room_id: room_id,
      instructor_conn: instructor_conn,
      instructor_token: instructor_token
    }
  end

  test "renders instructor lesson selection, preview, and timing controls", context do
    %{room_id: room_id, instructor_conn: conn, instructor_token: token} = context
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room_id}?access=#{token}")

    assert has_element?(view, "#classroom")
    assert has_element?(view, "#lesson-plan-picker")
    assert has_element?(view, "#lesson-command-preview")
    assert has_element?(view, "#lesson-config-form")
    assert has_element?(view, "#start-lesson[disabled]")
    assert has_element?(view, "#classroom-instructors")
    assert has_element?(view, "#classroom-students")

    view |> element("#lesson_plans-combined_sequence") |> render_click()
    assert has_element?(view, "#lesson-command-preview", "Combined flight sequence")

    view
    |> form("#lesson-config-form", %{
      "lesson" => %{
        "plan_id" => "combined_sequence",
        "attempt_duration_seconds" => "15",
        "maximum_attempts" => "2"
      }
    })
    |> render_submit()

    assert {:ok, snapshot} = Classrooms.snapshot(room_id)
    assert snapshot.plan.id == :combined_sequence
    assert snapshot.config.attempt_duration_seconds == 15
    assert snapshot.config.maximum_attempts == 2
  end

  test "starts two students with independent cockpits and live competition", context do
    %{room_id: room_id, instructor_conn: instructor_conn, instructor_token: instructor_token} =
      context

    {:ok, instructor_view, _html} =
      live(instructor_conn, ~p"/rooms/#{room_id}?access=#{instructor_token}")

    # All three connections deliberately share a browser identity. Signed student
    # participant IDs must still keep the aircraft and Presence entries separate.
    guest_id = "instructor-browser"
    {student_view, student_id} = join_student(room_id, guest_id, "Student Sam")
    {newest_student_view, newest_student_id} = join_student(room_id, guest_id, "Student Alex")

    assert has_element?(student_view, "#student-waiting-room")
    assert has_element?(newest_student_view, "#student-waiting-room")
    refute has_element?(student_view, "#student-cockpit")

    instructor_view |> element("#start-lesson") |> render_click()

    assert has_element?(instructor_view, "#atc-lesson-running")
    assert has_element?(student_view, "#student-cockpit")
    assert has_element?(student_view, "#primary-flight-display")
    assert has_element?(student_view, "#artificial-horizon")
    assert has_element?(student_view, "#airspeed-indicator")
    assert has_element?(student_view, "#altitude-indicator")
    assert has_element?(student_view, "#atc-current-command", "Set throttle to 65 percent")
    assert has_element?(student_view, "#throttle-up")

    student_view |> element("#throttle-up") |> render_click()
    student_view |> element("#throttle-up") |> render_click()
    newest_student_view |> element("#bank-right") |> render_click()

    assert {:ok, snapshot} = Classrooms.snapshot(room_id)
    assert find_student(snapshot, student_id).flight.throttle_percent == 65
    assert find_student(snapshot, student_id).flight.bank_deg == 0.0
    assert find_student(snapshot, newest_student_id).flight.throttle_percent == 55
    assert find_student(snapshot, newest_student_id).flight.bank_deg == 3.0

    {:ok, snapshot} = Classrooms.tick(room_id, 2_000)
    send(student_view.pid, {:classroom_updated, snapshot})
    send(instructor_view.pid, {:classroom_updated, snapshot})

    assert has_element?(student_view, "#leaderboard-#{student_id}", "+1")
    assert has_element?(student_view, "#atc-transcript", "Roger")
    assert has_element?(instructor_view, "#student_progress-#{student_id}")
    assert has_element?(instructor_view, "#student_progress-#{newest_student_id}")
  end

  test "instructor can pause, continue, and reset a running lesson", context do
    %{room_id: room_id, instructor_conn: conn, instructor_token: token} = context
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room_id}?access=#{token}")
    {_student_view, _student_id} = join_student(room_id, "student-browser", "Student Sam")

    view |> element("#start-lesson") |> render_click()
    view |> element("#pause-lesson") |> render_click()
    assert has_element?(view, "#continue-lesson")

    view |> element("#continue-lesson") |> render_click()
    assert has_element?(view, "#pause-lesson")

    view |> element("#reset-lesson") |> render_click()
    assert has_element?(view, "#lesson-plan-picker")
    assert has_element?(view, "#lesson-status", "waiting")
  end

  test "rejects a new student after the lesson starts", context do
    %{room_id: room_id, instructor_conn: conn, instructor_token: token} = context
    {:ok, instructor_view, _html} = live(conn, ~p"/rooms/#{room_id}?access=#{token}")
    {_student_view, _student_id} = join_student(room_id, "first-student", "Student Sam")
    instructor_view |> element("#start-lesson") |> render_click()

    guest_id = "late-student"
    access = ClassroomAccess.sign(room_id, guest_id, "Late Pilot", :student)
    late_conn = init_test_session(build_conn(), %{guest_id: guest_id})
    {:ok, late_view, _html} = live(late_conn, ~p"/rooms/#{room_id}?access=#{access}")

    assert has_element?(late_view, "#classroom-access-error")
    refute has_element?(late_view, "#student-cockpit")
  end

  test "rejects invalid access links", %{room_id: room_id, instructor_conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room_id}?access=invalid")

    assert has_element?(view, "#classroom-access-error")
    refute has_element?(view, "#student-cockpit")
  end

  defp join_student(room_id, guest_id, name) do
    token = ClassroomAccess.sign(room_id, guest_id, name, :student)
    assert {:ok, %{id: student_id}} = ClassroomAccess.verify(token, room_id, guest_id)
    conn = init_test_session(build_conn(), %{guest_id: guest_id})
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room_id}?access=#{token}")
    {view, student_id}
  end

  defp find_student(snapshot, id), do: Enum.find(snapshot.students, &(&1.id == id))
end
