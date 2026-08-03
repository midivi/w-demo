defmodule WailWeb.LobbyLiveTest do
  use WailWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Wail.Classrooms
  alias WailWeb.ClassroomAccess

  setup %{conn: conn} do
    {:ok, conn: init_test_session(conn, %{guest_id: "lobby-test-guest"})}
  end

  test "renders create and join forms with stable controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#lobby")
    assert has_element?(view, "#create-room-form")
    assert has_element?(view, "#create-room-button")
    assert has_element?(view, "#join-room-form")
    assert has_element?(view, "#join-room-button")
    assert has_element?(view, "#active-lessons-panel")
    assert has_element?(view, "#active-lesson-join-form")
    assert has_element?(view, "#join-room-callsign-note")
    assert has_element?(view, "#active-join-callsign-note")
    refute has_element?(view, "#join_name")
    refute has_element?(view, "#active_join_name")
  end

  test "creates a supervised room and redirects with signed access", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert {:error, {:live_redirect, %{to: destination}}} =
             view
             |> form("#create-room-form", %{"create" => %{"name" => "Captain Noor"}})
             |> render_submit()

    uri = URI.parse(destination)
    ["rooms", room_id] = String.split(uri.path, "/", trim: true)
    assert String.starts_with?(room_id, "SIM-")
    assert Classrooms.room_exists?(room_id)
    assert URI.decode_query(uri.query)["access"]

    room_pid = Classrooms.whereis(room_id)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Wail.Classrooms.Supervisor, room_pid)
    end)
  end

  test "public join routes prefill the room code", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/join/SIM-ABC123")

    assert has_element?(view, "#join-room-form input[value='SIM-ABC123']")
  end

  test "joins an existing room with a server-generated callsign", %{conn: conn} do
    {room_id, room_pid} = create_lesson_room("Captain Vega")
    on_exit(fn -> stop_room(room_pid) end)

    {:ok, view, _html} = live(conn, ~p"/join/#{room_id}")

    assert {:error, {:live_redirect, %{to: destination}}} =
             render_submit(view, "join_room", %{"join" => %{"room_id" => room_id}})

    uri = URI.parse(destination)
    token = URI.decode_query(uri.query)["access"]

    assert uri.path == "/rooms/#{room_id}"

    assert {:ok, %{display_name: display_name, role: :student}} =
             ClassroomAccess.verify(token, room_id, "lobby-test-guest")

    assert [_first_name, _animal] = String.split(display_name)
  end

  test "auto-join URL enrolls distinct random students without a form submission", %{conn: conn} do
    {room_id, room_pid} = create_lesson_room("Captain Vega")
    on_exit(fn -> stop_room(room_pid) end)

    auto_join_url = ~p"/join/#{room_id}?auto_join=true"

    first_destination = auto_join_destination(conn, auto_join_url)
    second_destination = auto_join_destination(conn, auto_join_url)

    {:ok, first_view, _html} = live(conn, first_destination)
    {:ok, second_view, _html} = live(conn, second_destination)

    assert has_element?(first_view, "#student-waiting-room")
    assert has_element?(second_view, "#student-waiting-room")

    assert {:ok, snapshot} = Classrooms.snapshot(room_id)
    assert length(snapshot.students) == 2
    assert snapshot.students |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 2
    assert Enum.all?(snapshot.students, &(length(String.split(&1.name)) == 2))
  end

  test "keeps the user in the lobby when a room is missing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#join-room-form", %{
      "join" => %{"room_id" => "SIM-MISSING"}
    })
    |> render_submit()

    assert has_element?(view, "#join-room-form")
    assert has_element?(view, "#flash-error")
  end

  test "lists a waiting lesson and joins it by clicking", %{conn: conn} do
    {room_id, room_pid} = create_lesson_room("Captain Vega")
    on_exit(fn -> stop_room(room_pid) end)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#lessons-#{room_id}", "Basic aircraft control")
    assert has_element?(view, "#join-active-#{room_id}:not([disabled])")

    assert {:error, {:live_redirect, %{to: destination}}} =
             render_submit(view, "join_active", %{
               "active_join" => %{"room_id" => room_id}
             })

    assert URI.parse(destination).path == "/rooms/#{room_id}"
    assert URI.decode_query(URI.parse(destination).query)["access"]
  end

  test "shows running lessons but disables new enrollment", %{conn: conn} do
    {room_id, room_pid} = create_lesson_room("Captain Vega")
    on_exit(fn -> stop_room(room_pid) end)

    instructor = %{id: "instructor-#{room_id}", display_name: "Captain Vega", role: :instructor}
    student = %{id: "student-#{room_id}", display_name: "Student Sam", role: :student}

    assert {:ok, _snapshot} = Classrooms.enroll(room_id, student)
    assert {:ok, _snapshot} = Classrooms.lesson_action(room_id, instructor, :start)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#lessons-#{room_id}", "In progress")
    assert has_element?(view, "#join-active-#{room_id}[disabled]")
  end

  defp create_lesson_room(instructor_name) do
    room_id = "SIM-LOBBY#{System.unique_integer([:positive])}"
    instructor_id = "instructor-#{room_id}"

    {:ok, room} =
      Classrooms.create_room(instructor_id,
        room_id: room_id,
        instructor_name: instructor_name,
        tick_interval: :manual,
        idle_timeout: :timer.minutes(1)
      )

    {room_id, room.pid}
  end

  defp auto_join_destination(conn, url) do
    assert {:error, {redirect_kind, %{to: destination}}} = live(conn, url)
    assert redirect_kind in [:redirect, :live_redirect]
    destination
  end

  defp stop_room(pid) do
    if Process.alive?(pid) do
      DynamicSupervisor.terminate_child(Wail.Classrooms.Supervisor, pid)
    end
  end
end
