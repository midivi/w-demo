defmodule Wail.Classrooms.ClassroomServer do
  @moduledoc "Owns one classroom, its ATC lesson, and every enrolled student's aircraft."

  use GenServer

  alias Wail.Classrooms
  alias Wail.Classrooms.FlightModel
  alias Wail.Classrooms.LessonCommand
  alias Wail.Classrooms.LessonEngine
  alias Wail.Classrooms.LessonPlan
  alias Wail.Classrooms.StudentSession

  @default_tick_interval 250
  @default_broadcast_interval 1_000
  @default_idle_timeout :timer.minutes(10)
  @default_config %{
    attempt_duration_ms: 30_000,
    maximum_attempts: 3,
    hold_duration_ms: 2_000
  }

  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via(room_id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :room_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def snapshot(server), do: GenServer.call(server, :snapshot)
  def listing(server), do: GenServer.call(server, :listing)
  def enroll(server, participant), do: GenServer.call(server, {:enroll, participant})

  def configure_lesson(server, participant, attrs),
    do: GenServer.call(server, {:configure_lesson, participant, attrs})

  def lesson_action(server, participant, action),
    do: GenServer.call(server, {:lesson_action, participant, action})

  def flight_command(server, participant, command),
    do: GenServer.call(server, {:flight_command, participant, command})

  def tick(server, elapsed_ms \\ @default_tick_interval),
    do: GenServer.call(server, {:tick, elapsed_ms})

  def presence_changed(server, participant_count),
    do: GenServer.cast(server, {:presence_changed, participant_count})

  @impl true
  def init(opts) do
    plan = LessonPlan.default()

    state = %{
      room_id: Keyword.fetch!(opts, :room_id),
      instructor: %{
        id: Keyword.fetch!(opts, :instructor_id),
        name: Keyword.get(opts, :instructor_name, "Instructor")
      },
      created_at: DateTime.utc_now(),
      status: :waiting,
      selected_plan_id: plan.id,
      lesson_config: @default_config,
      students: %{},
      participant_count: 0,
      idle_timer: nil,
      tick_timer: nil,
      tick_interval: Keyword.get(opts, :tick_interval, @default_tick_interval),
      broadcast_interval: Keyword.get(opts, :broadcast_interval, @default_broadcast_interval),
      broadcast_elapsed_ms: 0,
      idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout),
      last_tick_at: monotonic_ms()
    }

    {:ok, schedule_idle_shutdown(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, build_snapshot(state)}, state}
  def handle_call(:listing, _from, state), do: {:reply, build_listing(state), state}

  def handle_call({:enroll, participant}, _from, state) do
    case enroll_participant(state, participant) do
      {:ok, state, changed?} ->
        if changed?, do: broadcast_all(state)
        {:reply, {:ok, build_participant_snapshot(state, participant)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:configure_lesson, participant, attrs}, _from, state) do
    with :ok <- authorize_instructor(state, participant),
         :ok <- require_status(state, :waiting),
         {:ok, plan} <- configured_plan(state, attrs),
         {:ok, config} <- configured_timing(state, attrs) do
      students =
        Map.new(state.students, fn {id, student} ->
          {id, reset_student(student, config)}
        end)

      state = %{
        state
        | selected_plan_id: plan.id,
          lesson_config: config,
          students: students
      }

      broadcast_all(state)
      {:reply, {:ok, build_participant_snapshot(state, participant)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lesson_action, participant, action}, _from, state) do
    with :ok <- authorize_instructor(state, participant),
         {:ok, state} <- apply_lesson_action(state, action) do
      state = sync_tick_timer(state)
      broadcast_all(state)
      {:reply, {:ok, build_participant_snapshot(state, participant)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:flight_command, participant, command}, _from, state) do
    with :ok <- require_status(state, [:running, :paused]),
         {:ok, student} <- enrolled_student(state, participant),
         :ok <- supported_student_command(command),
         {:ok, flight} <- FlightModel.apply_command(student.flight, command) do
      student = %{student | flight: flight}
      state = put_in(state.students[student.id], student)
      {:reply, {:ok, build_participant_snapshot(state, participant)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:tick, elapsed_ms}, _from, state)
      when is_integer(elapsed_ms) and elapsed_ms > 0 do
    {state, status_changed?} = advance(state, elapsed_ms)
    state = sync_tick_timer(state)
    if status_changed?, do: broadcast_all(state), else: broadcast(state)
    {:reply, {:ok, build_snapshot(state)}, state}
  end

  @impl true
  def handle_cast({:presence_changed, participant_count}, state) do
    state = %{state | participant_count: max(participant_count, 0)}

    state =
      if state.participant_count == 0 do
        schedule_idle_shutdown(state)
      else
        cancel_idle_shutdown(state)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:tick, token}, %{tick_timer: {_timer_ref, token}} = state) do
    now = monotonic_ms()
    elapsed_ms = max(now - state.last_tick_at, 1)
    state = %{state | last_tick_at: now, tick_timer: nil}
    {state, status_changed?} = advance(state, elapsed_ms)
    broadcast_elapsed_ms = state.broadcast_elapsed_ms + elapsed_ms

    state =
      if status_changed? or broadcast_elapsed_ms >= state.broadcast_interval do
        broadcast(state)
        %{state | broadcast_elapsed_ms: 0}
      else
        %{state | broadcast_elapsed_ms: broadcast_elapsed_ms}
      end

    if status_changed?, do: broadcast_listing_changed(state.room_id)
    {:noreply, sync_tick_timer(state)}
  end

  def handle_info({:tick, _token}, state), do: {:noreply, state}

  def handle_info(
        {:idle_shutdown, token},
        %{idle_timer: {_timer_ref, token}, participant_count: 0} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info({:idle_shutdown, _token}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    broadcast_listing_changed(state.room_id)
    :ok
  end

  defp enroll_participant(state, %{id: id, role: :instructor})
       when id == state.instructor.id,
       do: {:ok, state, false}

  defp enroll_participant(state, %{id: id, role: :student} = participant) do
    cond do
      Map.has_key?(state.students, id) ->
        {:ok, state, false}

      state.status == :waiting ->
        student = StudentSession.new(participant, state.lesson_config.attempt_duration_ms)
        {:ok, put_in(state.students[id], student), true}

      true ->
        {:error, :lesson_not_joinable}
    end
  end

  defp enroll_participant(_state, _participant), do: {:error, :forbidden}

  defp apply_lesson_action(state, :start) do
    with :ok <- require_status(state, :waiting),
         :ok <- require_students(state),
         {:ok, plan} <- LessonPlan.fetch(state.selected_plan_id) do
      students =
        Map.new(state.students, fn {id, student} ->
          student = %{student | flight: FlightModel.new()}
          {id, LessonEngine.start(student, plan, state.lesson_config)}
        end)

      {:ok, %{state | students: students, status: :running, last_tick_at: monotonic_ms()}}
    end
  end

  defp apply_lesson_action(state, :pause) do
    with :ok <- require_status(state, :running), do: {:ok, %{state | status: :paused}}
  end

  defp apply_lesson_action(state, :continue) do
    with :ok <- require_status(state, :paused) do
      {:ok, %{state | status: :running, last_tick_at: monotonic_ms()}}
    end
  end

  defp apply_lesson_action(state, :reset) do
    with :ok <- require_status(state, [:running, :paused, :completed]) do
      students =
        Map.new(state.students, fn {id, student} ->
          {id, reset_student(student, state.lesson_config)}
        end)

      {:ok, %{state | status: :waiting, students: students}}
    end
  end

  defp apply_lesson_action(_state, _action), do: {:error, :unsupported_action}

  defp advance(state, elapsed_ms) do
    seconds = elapsed_ms / 1_000

    students =
      Map.new(state.students, fn {id, student} ->
        {id, %{student | flight: FlightModel.advance(student.flight, seconds)}}
      end)

    students =
      if state.status == :running do
        {:ok, plan} = LessonPlan.fetch(state.selected_plan_id)

        Map.new(students, fn {id, student} ->
          {id, LessonEngine.advance(student, plan, state.lesson_config, elapsed_ms)}
        end)
      else
        students
      end

    next_status =
      if state.status == :running and map_size(students) > 0 and
           Enum.all?(students, fn {_id, student} -> student.completed? end) do
        :completed
      else
        state.status
      end

    {%{state | students: students, status: next_status}, next_status != state.status}
  end

  defp reset_student(student, config) do
    student
    |> Map.put(:flight, FlightModel.new())
    |> LessonEngine.reset(config)
  end

  defp configured_plan(state, attrs) do
    attrs
    |> fetch_attr(:plan_id, Atom.to_string(state.selected_plan_id))
    |> LessonPlan.fetch()
  end

  defp configured_timing(state, attrs) do
    duration =
      fetch_attr(
        attrs,
        :attempt_duration_seconds,
        div(state.lesson_config.attempt_duration_ms, 1_000)
      )

    attempts = fetch_attr(attrs, :maximum_attempts, state.lesson_config.maximum_attempts)

    with {:ok, duration} <- parse_bounded_integer(duration, 5, 120),
         {:ok, attempts} <- parse_bounded_integer(attempts, 1, 5) do
      {:ok,
       %{
         state.lesson_config
         | attempt_duration_ms: duration * 1_000,
           maximum_attempts: attempts
       }}
    else
      _error -> {:error, :invalid_lesson_config}
    end
  end

  defp fetch_attr(attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp parse_bounded_integer(value, minimum, maximum) when is_integer(value) do
    if value in minimum..maximum, do: {:ok, value}, else: {:error, :out_of_range}
  end

  defp parse_bounded_integer(value, minimum, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> parse_bounded_integer(integer, minimum, maximum)
      _other -> {:error, :invalid_integer}
    end
  end

  defp parse_bounded_integer(_value, _minimum, _maximum), do: {:error, :invalid_integer}

  defp require_students(%{students: students}) when map_size(students) > 0, do: :ok
  defp require_students(_state), do: {:error, :no_students}

  defp require_status(%{status: status}, status), do: :ok

  defp require_status(%{status: status}, statuses) when is_list(statuses) do
    if status in statuses, do: :ok, else: {:error, :invalid_lesson_state}
  end

  defp require_status(_state, _expected), do: {:error, :invalid_lesson_state}

  defp authorize_instructor(state, %{id: id, role: :instructor})
       when id == state.instructor.id,
       do: :ok

  defp authorize_instructor(_state, _participant), do: {:error, :forbidden}

  defp enrolled_student(state, %{id: id, role: :student}) do
    case Map.fetch(state.students, id) do
      {:ok, student} -> {:ok, student}
      :error -> {:error, :forbidden}
    end
  end

  defp enrolled_student(_state, _participant), do: {:error, :forbidden}

  defp supported_student_command(command)
       when command in [:level] or
              (is_tuple(command) and tuple_size(command) == 3 and elem(command, 0) == :adjust),
       do: :ok

  defp supported_student_command(_command), do: {:error, :unsupported_command}

  defp base_snapshot(state, plan) do
    %{
      room_id: state.room_id,
      created_at: state.created_at,
      instructor: state.instructor,
      participant_count: state.participant_count,
      status: state.status,
      joinable?: state.status == :waiting,
      plan: plan_snapshot(plan),
      config: config_snapshot(state.lesson_config)
    }
  end

  defp build_snapshot(state) do
    {:ok, plan} = LessonPlan.fetch(state.selected_plan_id)

    students =
      state.students |> Map.values() |> Enum.map(&student_snapshot(&1, plan, state.lesson_config))

    Map.merge(base_snapshot(state, plan), %{
      students: students,
      leaderboard: build_leaderboard(state)
    })
  end

  defp build_participant_snapshot(state, %{role: :instructor}), do: build_snapshot(state)

  # Answering one student's command must not cost a rebuild of the whole class.
  # Only their own aircraft is rendered, so only their own aircraft is built.
  defp build_participant_snapshot(state, %{role: :student, id: student_id}) do
    {:ok, plan} = LessonPlan.fetch(state.selected_plan_id)

    students =
      case Map.fetch(state.students, student_id) do
        {:ok, student} -> [student_snapshot(student, plan, state.lesson_config)]
        :error -> []
      end

    Map.merge(base_snapshot(state, plan), %{
      students: students,
      leaderboard: build_leaderboard(state)
    })
  end

  # Built from the raw sessions rather than from rendered student snapshots, so
  # scoring a leaderboard never forces a full snapshot of every student.
  defp build_leaderboard(state) do
    state.students
    |> Map.values()
    |> Enum.map(
      &%{id: &1.id, name: &1.name, score: &1.score, commands_judged: length(&1.results)}
    )
    |> Enum.sort_by(&{-&1.score, -&1.commands_judged, String.downcase(&1.name)})
  end

  defp student_snapshot(student, plan, config) do
    command = LessonEngine.current_command(student, plan)

    %{
      id: student.id,
      name: student.name,
      score: student.score,
      flight: FlightModel.display_snapshot(student.flight),
      command_index: student.command_index,
      command_number: min(student.command_index + 1, length(plan.commands)),
      current_command: command && command_snapshot(command),
      attempt: student.attempt,
      attempt_remaining_ms: student.attempt_remaining_ms,
      hold_elapsed_ms: student.hold_elapsed_ms,
      hold_duration_ms: config.hold_duration_ms,
      target_acquired?: student.target_acquired?,
      results: student.results,
      transcript: student.transcript,
      completed?: student.completed?
    }
  end

  defp build_listing(state) do
    {:ok, plan} = LessonPlan.fetch(state.selected_plan_id)

    %{
      id: state.room_id,
      room_id: state.room_id,
      instructor_name: state.instructor.name,
      plan_name: plan.name,
      plan_description: plan.description,
      status: state.status,
      enrolled_count: map_size(state.students),
      attempt_duration_seconds: div(state.lesson_config.attempt_duration_ms, 1_000),
      maximum_attempts: state.lesson_config.maximum_attempts,
      joinable?: state.status == :waiting
    }
  end

  defp plan_snapshot(plan) do
    %{
      id: plan.id,
      name: plan.name,
      description: plan.description,
      commands: Enum.map(plan.commands, &command_snapshot/1)
    }
  end

  defp command_snapshot(command) do
    %{
      id: command.id,
      name: command.name,
      instruction: command.instruction,
      metric: command.metric,
      minimum: command.minimum,
      maximum: command.maximum,
      unit: command.unit,
      target_label: LessonCommand.target_label(command)
    }
  end

  defp config_snapshot(config) do
    %{
      attempt_duration_seconds: div(config.attempt_duration_ms, 1_000),
      maximum_attempts: config.maximum_attempts,
      hold_duration_seconds: div(config.hold_duration_ms, 1_000)
    }
  end

  defp broadcast_all(state) do
    broadcast(state)
    broadcast_listing_changed(state.room_id)
  end

  defp broadcast(state) do
    snapshot = build_snapshot(state)
    instructor = %{role: :instructor, id: state.instructor.id}
    students_by_id = Map.new(snapshot.students, &{&1.id, &1})

    Phoenix.PubSub.broadcast(
      Wail.PubSub,
      Classrooms.updates_topic(state.room_id, instructor),
      {:classroom_updated, snapshot}
    )

    Enum.each(Map.keys(state.students), fn student_id ->
      participant = %{role: :student, id: student_id}
      student_snapshot = %{snapshot | students: [Map.fetch!(students_by_id, student_id)]}

      Phoenix.PubSub.broadcast(
        Wail.PubSub,
        Classrooms.updates_topic(state.room_id, participant),
        {:classroom_updated, student_snapshot}
      )
    end)
  end

  defp broadcast_listing_changed(room_id) do
    Phoenix.PubSub.broadcast(
      Wail.PubSub,
      Classrooms.lobby_topic(),
      {:classroom_listing_changed, room_id}
    )
  end

  defp sync_tick_timer(%{status: status} = state) when status in [:running, :paused],
    do: schedule_tick(state)

  defp sync_tick_timer(state), do: cancel_tick(state)

  defp schedule_tick(%{tick_interval: :manual} = state), do: state
  defp schedule_tick(%{tick_timer: {_timer_ref, _token}} = state), do: state

  defp schedule_tick(state) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, token}, state.tick_interval)
    %{state | tick_timer: {timer_ref, token}}
  end

  defp cancel_tick(%{tick_timer: nil} = state), do: state

  defp cancel_tick(state) do
    {timer_ref, _token} = state.tick_timer
    Process.cancel_timer(timer_ref)
    %{state | tick_timer: nil, broadcast_elapsed_ms: 0}
  end

  defp schedule_idle_shutdown(state) do
    state = cancel_idle_shutdown(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:idle_shutdown, token}, state.idle_timeout)
    %{state | idle_timer: {timer_ref, token}}
  end

  defp cancel_idle_shutdown(%{idle_timer: nil} = state), do: state

  defp cancel_idle_shutdown(state) do
    {timer_ref, _token} = state.idle_timer
    Process.cancel_timer(timer_ref)
    %{state | idle_timer: nil}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp via(room_id), do: {:via, Registry, {Wail.Classrooms.Registry, room_id}}
end
