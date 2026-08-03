defmodule WailWeb.ClassroomLive do
  use WailWeb, :live_view

  alias Wail.Classrooms
  alias Wail.Classrooms.LessonPlan
  alias WailWeb.ClassroomAccess
  alias WailWeb.ClassroomPresence

  @impl true
  def mount(%{"room_id" => room_id} = params, session, socket) do
    room_id = Classrooms.normalize_room_id(room_id)
    guest_id = Map.fetch!(session, "guest_id")

    with {:ok, participant} <- ClassroomAccess.verify(params["access"], room_id, guest_id),
         {:ok, snapshot} <- Classrooms.enroll(room_id, participant) do
      topic = Classrooms.topic(room_id)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Wail.PubSub, topic)
        Phoenix.PubSub.subscribe(Wail.PubSub, Classrooms.updates_topic(room_id, participant))

        {:ok, _presence_ref} =
          ClassroomPresence.track(self(), topic, participant.id, %{
            id: participant.id,
            name: participant.display_name,
            role: participant.role,
            joined_at: DateTime.utc_now()
          })
      end

      roster = roster(topic)
      {instructors, students} = Enum.split_with(roster, &(&1.role == :instructor))

      socket =
        socket
        |> assign(:page_title, "#{room_id} ATC lesson")
        |> assign(:access_error, nil)
        |> assign(:room_id, room_id)
        |> assign(:participant, participant)
        |> assign(:participant_count, length(roster))
        |> assign(:student_count, length(students))
        |> assign(:student_join_url, WailWeb.Endpoint.url() <> ~p"/join/#{room_id}")
        |> assign(
          :student_auto_join_url,
          WailWeb.Endpoint.url() <> ~p"/join/#{room_id}?auto_join=true"
        )
        |> assign(:plans, LessonPlan.list())
        |> stream(:instructors, instructors)
        |> stream(:students, students)
        |> stream(:lesson_plans, LessonPlan.list())
        |> sync_snapshot(snapshot, initial?: true)

      {:ok, socket}
    else
      {:error, :room_not_found} ->
        {:ok, error_socket(socket, room_id, "This classroom has expired or does not exist.")}

      {:error, :invalid_access} ->
        {:ok, error_socket(socket, room_id, "This classroom link is invalid or has expired.")}

      {:error, :lesson_not_joinable} ->
        {:ok,
         error_socket(
           socket,
           room_id,
           "This ATC lesson is already underway. New pilots cannot join after departure."
         )}
    end
  end

  @impl true
  def handle_event("flight_command", %{"command" => command_name}, socket) do
    with {:ok, command} <- parse_flight_command(command_name),
         {:ok, snapshot} <-
           Classrooms.flight_command(
             socket.assigns.room_id,
             socket.assigns.participant,
             command
           ) do
      {:noreply, sync_snapshot(socket, snapshot)}
    else
      {:error, :invalid_lesson_state} ->
        {:noreply, put_flash(socket, :error, "Flight controls activate when the lesson starts.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "That aircraft is not assigned to you.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That flight command was not accepted.")}
    end
  end

  def handle_event("select_plan", %{"plan_id" => plan_id}, socket) do
    case Classrooms.configure_lesson(
           socket.assigns.room_id,
           socket.assigns.participant,
           %{plan_id: plan_id}
         ) do
      {:ok, snapshot} -> {:noreply, sync_snapshot(socket, snapshot)}
      {:error, reason} -> {:noreply, lesson_error(socket, reason)}
    end
  end

  def handle_event("configure_lesson", %{"lesson" => params}, socket) do
    case Classrooms.configure_lesson(
           socket.assigns.room_id,
           socket.assigns.participant,
           params
         ) do
      {:ok, snapshot} ->
        {:noreply,
         socket
         |> sync_snapshot(snapshot)
         |> put_flash(:info, "Lesson settings updated.")}

      {:error, reason} ->
        {:noreply, lesson_error(socket, reason)}
    end
  end

  def handle_event("lesson_action", %{"action" => action_name}, socket) do
    with {:ok, action} <- parse_lesson_action(action_name),
         {:ok, snapshot} <-
           Classrooms.lesson_action(
             socket.assigns.room_id,
             socket.assigns.participant,
             action
           ) do
      {:noreply, sync_snapshot(socket, snapshot)}
    else
      {:error, reason} -> {:noreply, lesson_error(socket, reason)}
    end
  end

  @impl true
  def handle_info({:classroom_updated, snapshot}, socket) do
    {:noreply, sync_snapshot(socket, snapshot)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    roster = roster(Classrooms.topic(socket.assigns.room_id))
    {instructors, students} = Enum.split_with(roster, &(&1.role == :instructor))

    {:noreply,
     socket
     |> assign(:participant_count, length(roster))
     |> assign(:student_count, length(students))
     |> stream(:instructors, instructors, reset: true)
     |> stream(:students, students, reset: true)}
  end

  defp sync_snapshot(socket, snapshot, opts \\ []) do
    previous = socket.assigns[:snapshot]
    participant = socket.assigns.participant
    initial? = Keyword.get(opts, :initial?, false)
    current_student = Enum.find(snapshot.students, &(&1.id == participant.id))
    transcript = transcript_for(snapshot, participant)
    command_progress = command_progress(snapshot.plan.commands, current_student)
    config_changed? = previous == nil or previous.config != snapshot.config
    plan_changed? = previous == nil or previous.plan.id != snapshot.plan.id

    socket =
      socket
      |> assign(:snapshot, snapshot)
      |> assign(:current_student, current_student)
      |> assign(:lesson_in_progress?, snapshot.status in [:running, :paused])
      |> maybe_stream(
        :leaderboard,
        snapshot.leaderboard,
        previous && previous.leaderboard,
        initial?
      )
      |> maybe_stream_for_role(
        :student_progress,
        snapshot.students,
        previous && previous.students,
        initial?,
        participant,
        :instructor
      )
      |> maybe_stream(
        :transcript,
        transcript,
        previous && transcript_for(previous, participant),
        initial?
      )
      |> maybe_stream_for_role(
        :command_progress,
        command_progress,
        previous &&
          command_progress(previous.plan.commands, current_student_for(previous, participant)),
        initial?,
        participant,
        :student
      )

    socket =
      if config_changed? or plan_changed? do
        assign(socket, :lesson_form, lesson_form(snapshot))
      else
        socket
      end

    if plan_changed? or initial? do
      stream(socket, :lesson_commands, snapshot.plan.commands, reset: !initial?)
    else
      socket
    end
  end

  defp maybe_stream(socket, name, items, previous_items, initial?) do
    if initial? or items != previous_items do
      stream(socket, name, items, reset: !initial?)
    else
      socket
    end
  end

  defp maybe_stream_for_role(
         socket,
         name,
         items,
         previous_items,
         initial?,
         %{role: role},
         role
       ) do
    maybe_stream(socket, name, items, previous_items, initial?)
  end

  defp maybe_stream_for_role(
         socket,
         _name,
         _items,
         _previous_items,
         _initial?,
         _participant,
         _role
       ),
       do: socket

  defp current_student_for(snapshot, %{role: :student, id: id}) do
    Enum.find(snapshot.students, &(&1.id == id))
  end

  defp current_student_for(_snapshot, %{role: :instructor}), do: nil

  defp transcript_for(snapshot, %{role: :student, id: id}) do
    case Enum.find(snapshot.students, &(&1.id == id)) do
      nil -> []
      student -> Enum.map(student.transcript, &Map.put(&1, :student_name, student.name))
    end
  end

  defp transcript_for(snapshot, %{role: :instructor}) do
    snapshot.students
    |> Enum.flat_map(fn student ->
      Enum.map(student.transcript, &Map.put(&1, :student_name, student.name))
    end)
    |> Enum.sort_by(&{&1.sequence, &1.student_name})
    |> Enum.take(-50)
  end

  defp command_progress(commands, nil) do
    Enum.map(commands, &Map.merge(&1, %{status: :pending, attempts: nil}))
  end

  defp command_progress(commands, student) do
    commands
    |> Enum.with_index()
    |> Enum.map(fn {command, index} ->
      result = Enum.find(student.results, &(&1.command_id == command.id))

      status =
        cond do
          result -> result.status
          !student.completed? and index == student.command_index -> :active
          true -> :pending
        end

      Map.merge(command, %{status: status, attempts: result && result.attempts})
    end)
  end

  defp lesson_form(snapshot) do
    to_form(
      %{
        "plan_id" => Atom.to_string(snapshot.plan.id),
        "attempt_duration_seconds" => snapshot.config.attempt_duration_seconds,
        "maximum_attempts" => snapshot.config.maximum_attempts
      },
      as: :lesson
    )
  end

  defp parse_flight_command("throttle_up"), do: {:ok, {:adjust, :throttle, 5}}
  defp parse_flight_command("throttle_down"), do: {:ok, {:adjust, :throttle, -5}}
  defp parse_flight_command("pitch_up"), do: {:ok, {:adjust, :pitch, 1}}
  defp parse_flight_command("pitch_down"), do: {:ok, {:adjust, :pitch, -1}}
  defp parse_flight_command("bank_left"), do: {:ok, {:adjust, :bank, -3}}
  defp parse_flight_command("bank_right"), do: {:ok, {:adjust, :bank, 3}}
  defp parse_flight_command("level"), do: {:ok, :level}
  defp parse_flight_command(_command), do: {:error, :unsupported_command}

  defp parse_lesson_action("start"), do: {:ok, :start}
  defp parse_lesson_action("pause"), do: {:ok, :pause}
  defp parse_lesson_action("continue"), do: {:ok, :continue}
  defp parse_lesson_action("reset"), do: {:ok, :reset}
  defp parse_lesson_action(_action), do: {:error, :unsupported_action}

  defp lesson_error(socket, :no_students),
    do: put_flash(socket, :error, "Enroll at least one student before starting.")

  defp lesson_error(socket, :invalid_lesson_config),
    do: put_flash(socket, :error, "Use 5–120 seconds and 1–5 attempts.")

  defp lesson_error(socket, :invalid_lesson_state),
    do: put_flash(socket, :error, "That action is not available in the current lesson state.")

  defp lesson_error(socket, :forbidden),
    do: put_flash(socket, :error, "Only the classroom instructor can do that.")

  defp lesson_error(socket, _reason),
    do: put_flash(socket, :error, "The lesson action could not be completed.")

  defp roster(topic) do
    topic
    |> ClassroomPresence.list()
    |> Enum.map(fn {id, %{metas: metas}} ->
      meta = List.first(metas)
      %{id: id, name: meta.name, role: meta.role, connections: length(metas)}
    end)
    |> Enum.sort_by(fn participant ->
      {if(participant.role == :instructor, do: 0, else: 1), String.downcase(participant.name)}
    end)
  end

  defp error_socket(socket, room_id, message) do
    socket
    |> assign(:page_title, "Classroom unavailable")
    |> assign(:room_id, room_id)
    |> assign(:access_error, message)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={assigns[:current_scope]}>
      <%= if @access_error do %>
        <section
          id="classroom-access-error"
          class={["mx-auto flex min-h-[70vh] max-w-xl items-center"]}
        >
          <div class={[
            "w-full rounded-3xl border border-rose-300/15 bg-white/90 p-8 text-center shadow-2xl"
          ]}>
            <span class={[
              "mx-auto flex size-14 items-center justify-center rounded-2xl bg-rose-300/10 text-rose-700"
            ]}>
              <.icon name="hero-lock-closed" class={["size-6"]} />
            </span>
            <h1 class={["mt-5 text-2xl font-black text-slate-950"]}>Unable to join {@room_id}</h1>
            <p class={["mt-3 text-sm leading-6 text-slate-500"]}>{@access_error}</p>
            <.link
              navigate={~p"/"}
              class={[
                "mt-6 inline-flex items-center gap-2 rounded-xl bg-cyan-300 px-4 py-3 text-sm font-extrabold text-slate-950"
              ]}
            >
              View active lessons <.icon name="hero-arrow-right" class={["size-4"]} />
            </.link>
          </div>
        </section>
      <% else %>
        <main id="classroom" class={["mx-auto max-w-[100rem] py-6"]}>
          <header class={[
            "mb-5 flex flex-col gap-4 rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-xl lg:flex-row lg:items-center lg:justify-between"
          ]}>
            <div class={["flex items-center gap-4"]}>
              <.link
                navigate={~p"/"}
                id="back-to-lobby"
                class={[
                  "flex size-10 items-center justify-center rounded-xl border border-slate-200 bg-slate-50 text-slate-500 transition hover:border-cyan-300/25 hover:text-cyan-700"
                ]}
              >
                <.icon name="hero-arrow-left" class={["size-4"]} />
              </.link>
              <div>
                <div class={["flex flex-wrap items-center gap-2"]}>
                  <span class={["font-mono text-xs font-bold tracking-wider text-cyan-700"]}>{@room_id}</span>
                  <span
                    id="lesson-status"
                    class={[
                      "rounded-full border px-2.5 py-1 text-[0.55rem] font-black uppercase tracking-[0.15em]",
                      status_class(@snapshot.status)
                    ]}
                  >
                    {status_label(@snapshot.status)}
                  </span>
                </div>
                <h1 class={["mt-1 text-xl font-black tracking-tight text-slate-950"]}>
                  {@snapshot.plan.name}
                </h1>
              </div>
            </div>
            <div class={["flex flex-wrap items-center gap-2"]}>
              <span class={[
                "rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-500"
              ]}>
                {@snapshot.config.attempt_duration_seconds}s · {@snapshot.config.maximum_attempts} attempts · {@snapshot.config.hold_duration_seconds}s hold
              </span>
              <span class={[
                "rounded-xl border border-violet-300/15 bg-violet-300/[0.06] px-3 py-2 text-xs font-bold text-violet-700"
              ]}>
                {@participant.display_name} · {@participant.role}
              </span>
            </div>
          </header>

          <%= if @participant.role == :instructor do %>
            <.instructor_view
              snapshot={@snapshot}
              lesson_form={@lesson_form}
              streams={@streams}
              student_join_url={@student_join_url}
              student_auto_join_url={@student_auto_join_url}
            />
          <% else %>
            <.student_view snapshot={@snapshot} student={@current_student} streams={@streams} />
          <% end %>
        </main>
      <% end %>
    </Layouts.app>
    """
  end

  attr :snapshot, :map, required: true
  attr :lesson_form, :map, required: true
  attr :streams, :map, required: true
  attr :student_join_url, :string, required: true
  attr :student_auto_join_url, :string, required: true

  defp instructor_view(assigns) do
    ~H"""
    <div id="instructor-atc-console" class={["space-y-5"]}>
      <%= if @snapshot.status == :waiting do %>
        <div class={["grid gap-5 xl:grid-cols-[1.25fr_0.75fr]"]}>
          <section
            id="lesson-plan-picker"
            class={["rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-xl sm:p-6"]}
          >
            <div class={["flex items-start justify-between gap-4"]}>
              <div>
                <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-cyan-700"]}>
                  Lesson control
                </p>
                <h2 class={["mt-2 text-2xl font-black text-slate-950"]}>Choose the ATC sequence</h2>
                <p class={["mt-2 text-sm text-slate-500"]}>
                  Students can enroll while you review and configure the lesson.
                </p>
              </div>
              <span class={[
                "flex size-11 items-center justify-center rounded-2xl border border-cyan-300/15 bg-cyan-300/[0.06] text-cyan-700"
              ]}>
                <.icon name="hero-radio" class={["size-5"]} />
              </span>
            </div>

            <div id="lesson-plans" phx-update="stream" class={["mt-6 grid gap-3 md:grid-cols-2"]}>
              <button
                :for={{dom_id, plan} <- @streams.lesson_plans}
                id={dom_id}
                type="button"
                phx-click="select_plan"
                phx-value-plan_id={plan.id}
                class={[
                  "cursor-pointer rounded-2xl border p-4 text-left transition hover:-translate-y-0.5",
                  if(@snapshot.plan.id == plan.id,
                    do: "border-cyan-400 bg-cyan-50 shadow-lg shadow-cyan-100",
                    else: "border-slate-200 bg-slate-50 hover:border-slate-300"
                  )
                ]}
              >
                <span class={[
                  "text-[0.55rem] font-black uppercase tracking-[0.16em]",
                  if(@snapshot.plan.id == plan.id, do: "text-cyan-700", else: "text-slate-500")
                ]}>Lesson plan</span>
                <p class={["mt-2 text-sm font-black text-slate-950"]}>{plan.name}</p>
                <p class={["mt-1 line-clamp-2 text-xs leading-5 text-slate-500"]}>
                  {plan.description}
                </p>
                <span class={["mt-3 inline-flex text-[0.65rem] font-bold text-slate-500"]}>{length(
                  plan.commands
                )} commands</span>
              </button>
            </div>
          </section>

          <section
            id="lesson-command-preview"
            class={["rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-xl sm:p-6"]}
          >
            <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-violet-700"]}>
              Command preview
            </p>
            <h2 class={["mt-2 text-lg font-black text-slate-950"]}>{@snapshot.plan.name}</h2>
            <div id="lesson-commands" phx-update="stream" class={["mt-5 space-y-2"]}>
              <div
                :for={{dom_id, command} <- @streams.lesson_commands}
                id={dom_id}
                class={[
                  "flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-100/80 p-3"
                ]}
              >
                <span class={[
                  "flex size-7 shrink-0 items-center justify-center rounded-lg bg-violet-300/10 text-[0.65rem] font-black text-violet-700"
                ]}>
                  <.icon name="hero-chevron-right" class={["size-3.5"]} />
                </span>
                <div class={["min-w-0 flex-1"]}>
                  <p class={["text-xs font-bold text-slate-950"]}>{command.instruction}</p>
                  <p class={["mt-0.5 text-[0.6rem] text-slate-500"]}>
                    Accepted {command.target_label}
                  </p>
                </div>
              </div>
            </div>
          </section>
        </div>

        <div class={["grid gap-5 lg:grid-cols-[0.8fr_1.2fr]"]}>
          <section
            id="lesson-settings"
            class={["rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-xl"]}
          >
            <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-amber-700"]}>
              Timing
            </p>
            <.form
              for={@lesson_form}
              id="lesson-config-form"
              phx-submit="configure_lesson"
              class={["mt-4"]}
            >
              <.input field={@lesson_form[:plan_id]} type="hidden" />
              <div class={["grid gap-3 sm:grid-cols-2"]}>
                <.input
                  field={@lesson_form[:attempt_duration_seconds]}
                  type="number"
                  min="5"
                  max="120"
                  label="Seconds per attempt"
                  class={[
                    "w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-950 outline-none focus:border-amber-300/50"
                  ]}
                />
                <.input
                  field={@lesson_form[:maximum_attempts]}
                  type="number"
                  min="1"
                  max="5"
                  label="Maximum attempts"
                  class={[
                    "w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-950 outline-none focus:border-amber-300/50"
                  ]}
                />
              </div>
              <button
                id="save-lesson-settings"
                type="submit"
                class={[
                  "mt-4 inline-flex w-full cursor-pointer items-center justify-center gap-2 rounded-xl border border-amber-300/20 bg-amber-300/10 px-4 py-3 text-sm font-bold text-amber-700 transition hover:bg-amber-300/15"
                ]}
              >
                <.icon name="hero-adjustments-horizontal" class={["size-4"]} /> Save timing
              </button>
            </.form>
          </section>

          <section
            id="lesson-launch"
            class={[
              "rounded-3xl border border-cyan-300/15 bg-gradient-to-br from-cyan-300/[0.08] to-violet-300/[0.04] p-5 shadow-xl"
            ]}
          >
            <div class={["flex flex-col gap-5 sm:flex-row sm:items-center sm:justify-between"]}>
              <div>
                <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-cyan-700"]}>
                  Departure board
                </p>
                <h2 class={["mt-2 text-xl font-black text-slate-950"]}>
                  {length(@snapshot.students)} student{if(length(@snapshot.students) == 1,
                    do: "",
                    else: "s"
                  )} enrolled
                </h2>
                <p class={["mt-2 text-xs leading-5 text-slate-500"]}>
                  Starting locks enrollment and gives every student an independent aircraft.
                </p>
              </div>
              <button
                id="start-lesson"
                type="button"
                phx-click="lesson_action"
                phx-value-action="start"
                disabled={@snapshot.students == []}
                class={[
                  "inline-flex min-w-40 items-center justify-center gap-2 rounded-xl px-5 py-3 text-sm font-black transition",
                  if(@snapshot.students == [],
                    do: "cursor-not-allowed bg-slate-50 text-slate-500",
                    else:
                      "cursor-pointer bg-cyan-300 text-slate-950 hover:-translate-y-0.5 hover:bg-cyan-200"
                  )
                ]}
              >
                Start lesson <.icon name="hero-play" class={["size-4"]} />
              </button>
            </div>
            <div id="student-join-links" class={["mt-5 grid gap-3 sm:grid-cols-2"]}>
              <div class={["rounded-xl border border-slate-200 bg-slate-100/80 p-3"]}>
                <p class={["text-[0.55rem] font-black uppercase tracking-[0.16em] text-slate-500"]}>
                  Manual join link
                </p>
                <.link
                  id="student-join-url"
                  href={@student_join_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class={[
                    "mt-2 block break-all font-mono text-xs text-slate-500 transition hover:text-cyan-700"
                  ]}
                >
                  {@student_join_url}
                </.link>
              </div>
              <div class={["rounded-xl border border-violet-300/20 bg-violet-300/[0.07] p-3"]}>
                <div class={["flex items-center justify-between gap-3"]}>
                  <p class={[
                    "text-[0.55rem] font-black uppercase tracking-[0.16em] text-violet-700"
                  ]}>
                    Automatic test join
                  </p>
                  <span class={[
                    "rounded-full bg-violet-300/15 px-2 py-1 text-[0.5rem] font-black uppercase tracking-wider text-violet-700"
                  ]}>
                    No form
                  </span>
                </div>
                <.link
                  id="student-auto-join-url"
                  href={@student_auto_join_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class={[
                    "mt-2 block break-all font-mono text-xs font-bold text-violet-700 transition hover:text-violet-900"
                  ]}
                >
                  {@student_auto_join_url}
                </.link>
                <p
                  id="student-auto-join-help"
                  class={["mt-2 text-[0.65rem] leading-4 text-slate-500"]}
                >
                  Open this same URL in multiple tabs to create a random student in each tab.
                </p>
              </div>
            </div>
          </section>
        </div>
      <% else %>
        <section
          id="atc-lesson-running"
          class={[
            "rounded-3xl border border-cyan-300/15 bg-gradient-to-r from-cyan-300/[0.08] to-violet-300/[0.05] p-5 shadow-xl"
          ]}
        >
          <div class={["flex flex-col gap-5 md:flex-row md:items-center md:justify-between"]}>
            <div class={["flex items-center gap-4"]}>
              <span class={[
                "flex size-12 items-center justify-center rounded-2xl bg-cyan-300/10 text-cyan-700"
              ]}><.icon name="hero-radio" class={["size-5"]} /></span>
              <div>
                <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-cyan-700"]}>
                  ATC lesson {status_label(@snapshot.status)}
                </p>
                <h2 class={["mt-1 text-xl font-black text-slate-950"]}>{@snapshot.plan.name}</h2>
              </div>
            </div>
            <div class={["flex gap-2"]}>
              <button
                :if={@snapshot.status == :running}
                id="pause-lesson"
                type="button"
                phx-click="lesson_action"
                phx-value-action="pause"
                class={[
                  "inline-flex cursor-pointer items-center gap-2 rounded-xl border border-amber-300/20 bg-amber-300/10 px-4 py-2.5 text-xs font-bold text-amber-700 hover:bg-amber-300/15"
                ]}
              ><.icon name="hero-pause" class={["size-4"]} /> Pause</button>
              <button
                :if={@snapshot.status == :paused}
                id="continue-lesson"
                type="button"
                phx-click="lesson_action"
                phx-value-action="continue"
                class={[
                  "inline-flex cursor-pointer items-center gap-2 rounded-xl bg-emerald-300 px-4 py-2.5 text-xs font-black text-slate-950 hover:bg-emerald-200"
                ]}
              ><.icon name="hero-play" class={["size-4"]} /> Continue</button>
              <button
                id="reset-lesson"
                type="button"
                phx-click="lesson_action"
                phx-value-action="reset"
                class={[
                  "inline-flex cursor-pointer items-center gap-2 rounded-xl border border-slate-200 bg-slate-50 px-4 py-2.5 text-xs font-bold text-slate-600 hover:border-rose-300/40 hover:text-rose-700"
                ]}
              ><.icon name="hero-arrow-path" class={["size-4"]} /> Reset</button>
            </div>
          </div>
        </section>

        <div class={["grid gap-5 xl:grid-cols-[1.35fr_0.65fr]"]}>
          <.instructor_progress streams={@streams} snapshot={@snapshot} />
          <div class={["space-y-5"]}>
            <.leaderboard streams={@streams} />
            <.transcript streams={@streams} title="ATC frequency" instructor?={true} />
          </div>
        </div>
      <% end %>

      <.presence_panel streams={@streams} />
    </div>
    """
  end

  attr :snapshot, :map, required: true
  attr :student, :map, default: nil
  attr :streams, :map, required: true

  defp student_view(assigns) do
    ~H"""
    <div id="student-atc-console" class={["space-y-5"]}>
      <%= if @snapshot.status == :waiting do %>
        <section
          id="student-waiting-room"
          class={[
            "overflow-hidden rounded-3xl border border-violet-300/15 bg-white/90 shadow-2xl"
          ]}
        >
          <div class={[
            "border-b border-slate-200 bg-gradient-to-r from-violet-300/[0.09] to-cyan-300/[0.04] p-7 text-center"
          ]}>
            <span class={[
              "mx-auto flex size-14 items-center justify-center rounded-2xl bg-violet-300/10 text-violet-700"
            ]}><.icon name="hero-clock" class={["size-6"]} /></span>
            <p class={["mt-5 text-xs font-black uppercase tracking-[0.22em] text-violet-700"]}>
              Clearance pending
            </p>
            <h2 class={["mt-2 text-3xl font-black text-slate-950"]}>Waiting for the instructor</h2>
            <p class={["mx-auto mt-3 max-w-2xl text-sm leading-6 text-slate-500"]}>
              You are enrolled in {@snapshot.plan.name}. The cockpit activates when the instructor starts the lesson.
            </p>
          </div>
          <div class={["grid gap-6 p-6 lg:grid-cols-[1fr_0.7fr]"]}>
            <div>
              <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-cyan-700"]}>
                Flight plan
              </p>
              <div id="lesson-commands" phx-update="stream" class={["mt-4 grid gap-2 sm:grid-cols-2"]}>
                <div
                  :for={{dom_id, command} <- @streams.lesson_commands}
                  id={dom_id}
                  class={["rounded-xl border border-slate-200 bg-slate-50 p-3"]}
                >
                  <p class={["text-xs font-bold text-slate-950"]}>{command.instruction}</p>
                  <p class={["mt-1 text-[0.6rem] text-slate-500"]}>
                    Hold {command.target_label} for {@snapshot.config.hold_duration_seconds}s
                  </p>
                </div>
              </div>
            </div>
            <.leaderboard streams={@streams} />
          </div>
        </section>
      <% else %>
        <section
          id="student-lesson-status"
          class={[
            "rounded-3xl border border-cyan-300/15 bg-gradient-to-r from-cyan-300/[0.08] to-violet-300/[0.05] p-5 shadow-xl"
          ]}
        >
          <div class={["flex flex-col gap-5 lg:flex-row lg:items-center lg:justify-between"]}>
            <div class={["flex items-center gap-4"]}>
              <span class={[
                "relative flex size-12 items-center justify-center rounded-2xl bg-cyan-300/10 text-cyan-700"
              ]}>
                <span
                  :if={@snapshot.status == :running}
                  class={["absolute right-1 top-1 size-2 animate-pulse rounded-full bg-emerald-300"]}
                ></span>
                <.icon name="hero-radio" class={["size-5"]} />
              </span>
              <div>
                <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-cyan-700"]}>
                  ATC lesson {status_label(@snapshot.status)}
                </p>
                <h2 class={["mt-1 text-xl font-black text-slate-950"]}>{@snapshot.plan.name}</h2>
              </div>
            </div>
            <div class={["grid grid-cols-3 gap-2 text-center"]}>
              <.status_stat label="Score" value={@student.score} />
              <.status_stat
                label="Command"
                value={"#{@student.command_number}/#{length(@snapshot.plan.commands)}"}
              />
              <.status_stat
                label="Attempt"
                value={
                  if(@student.completed?,
                    do: "—",
                    else: "#{@student.attempt}/#{@snapshot.config.maximum_attempts}"
                  )
                }
              />
            </div>
          </div>
        </section>

        <div class={["grid gap-5 xl:grid-cols-[1.25fr_0.75fr]"]}>
          <div class={["space-y-5"]}>
            <.current_command student={@student} status={@snapshot.status} />
            <.cockpit student={@student} controls_enabled?={@snapshot.status in [:running, :paused]} />
          </div>
          <div class={["space-y-5"]}>
            <.command_checklist streams={@streams} />
            <.transcript streams={@streams} title="ATC transcript" instructor?={false} />
            <.leaderboard streams={@streams} />
          </div>
        </div>
      <% end %>
      <.presence_panel streams={@streams} />
    </div>
    """
  end

  attr :student, :map, required: true
  attr :status, :atom, required: true

  defp current_command(assigns) do
    remaining_seconds = Float.ceil(assigns.student.attempt_remaining_ms / 1_000, 1)

    hold_percent =
      min(round(assigns.student.hold_elapsed_ms / assigns.student.hold_duration_ms * 100), 100)

    assigns = assign(assigns, remaining_seconds: remaining_seconds, hold_percent: hold_percent)

    ~H"""
    <section
      id="atc-current-command"
      class={[
        "relative overflow-hidden rounded-3xl border border-cyan-200 bg-white/95 p-6 shadow-xl shadow-cyan-100/60"
      ]}
    >
      <div class={["absolute inset-y-0 left-0 w-1 bg-cyan-300"]}></div>
      <%= if @student.completed? do %>
        <div class={["flex items-center gap-4"]}>
          <span class={[
            "flex size-12 items-center justify-center rounded-2xl bg-emerald-300/10 text-emerald-700"
          ]}><.icon name="hero-check" class={["size-6"]} /></span>
          <div>
            <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-emerald-700"]}>
              ATC
            </p><h3 class={["mt-1 text-xl font-black text-slate-950"]}>
              Lesson complete. Maintain present course.
            </h3>
          </div>
        </div>
      <% else %>
        <div class={["flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between"]}>
          <div>
            <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-cyan-700"]}>
              Current ATC command
            </p>
            <h3 class={["mt-2 text-2xl font-black leading-tight text-slate-950"]}>
              {@student.current_command.instruction}
            </h3>
            <p class={["mt-2 text-xs text-slate-500"]}>
              Accepted range {@student.current_command.target_label}
            </p>
          </div>
          <div class={[
            "shrink-0 rounded-2xl border border-slate-200 bg-slate-100/90 px-5 py-3 text-center"
          ]}>
            <p class={["text-[0.55rem] font-black uppercase tracking-[0.16em] text-slate-500"]}>
              Time left
            </p>
            <p
              id="attempt-countdown"
              class={[
                "mt-1 font-mono text-2xl font-black",
                if(@remaining_seconds <= 5, do: "text-rose-700", else: "text-slate-950")
              ]}
            >
              {Float.to_string(@remaining_seconds)}s
            </p>
          </div>
        </div>
        <div class={["mt-5"]}>
          <div class={["mb-2 flex items-center justify-between text-[0.6rem]"]}>
            <span class={[
              "font-bold uppercase tracking-wider",
              if(@student.target_acquired?, do: "text-emerald-700", else: "text-slate-500")
            ]}>{if(@student.target_acquired?, do: "Target acquired — hold", else: "Acquire target")}</span>
            <span class={["font-mono text-slate-500"]}>{@hold_percent}%</span>
          </div>
          <div class={["h-2 overflow-hidden rounded-full bg-slate-50"]}>
            <div
              id="target-hold-progress"
              class={["h-full rounded-full bg-emerald-300 transition-all duration-200"]}
              style={"width: #{@hold_percent}%"}
            >
            </div>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  attr :student, :map, required: true
  attr :controls_enabled?, :boolean, required: true

  defp cockpit(assigns) do
    ~H"""
    <section
      id="student-cockpit"
      class={["rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-2xl"]}
    >
      <div class={["flex items-center justify-between"]}>
        <div>
          <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-violet-700"]}>
            Assigned aircraft
          </p><h3 class={["mt-1 text-lg font-black text-slate-950"]}>
            {@student.name}'s flight deck
          </h3>
        </div>
        <span class={[
          "rounded-full border border-emerald-300/15 bg-emerald-300/[0.06] px-2.5 py-1 text-[0.55rem] font-black uppercase tracking-wider text-emerald-700"
        ]}>Server linked</span>
      </div>
      <.primary_flight_display student={@student} />
      <div class={["mt-5 grid grid-cols-2 gap-3 md:grid-cols-4"]}>
        <.flight_metric id="altitude" label="Altitude" value={@student.flight.altitude_ft} unit="ft" />
        <.flight_metric id="airspeed" label="Airspeed" value={@student.flight.airspeed_kts} unit="kt" />
        <.flight_metric id="heading" label="Heading" value={@student.flight.heading_deg} unit="°" />
        <.flight_metric
          id="vertical-speed"
          label="Vertical speed"
          value={@student.flight.vertical_speed_fpm}
          unit="fpm"
        />
        <.flight_metric
          id="throttle"
          label="Throttle"
          value={@student.flight.throttle_percent}
          unit="%"
        />
        <.flight_metric
          id="pitch"
          label="Pitch"
          value={@student.flight.pitch_deg}
          unit="°"
          signed?={true}
        />
        <.flight_metric
          id="bank"
          label="Bank"
          value={@student.flight.bank_deg}
          unit="°"
          signed?={true}
        />
        <.flight_metric
          id="elapsed"
          label="Flight time"
          value={@student.flight.elapsed_seconds}
          unit="s"
        />
      </div>
      <div id="student-flight-controls" class={["mt-5 grid gap-3 md:grid-cols-3"]}>
        <.control_group
          label="Throttle"
          down="throttle_down"
          up="throttle_up"
          down_id="throttle-down"
          up_id="throttle-up"
          disabled={!@controls_enabled?}
        />
        <.control_group
          label="Pitch"
          down="pitch_down"
          up="pitch_up"
          down_id="pitch-down"
          up_id="pitch-up"
          disabled={!@controls_enabled?}
        />
        <.control_group
          label="Bank"
          down="bank_left"
          up="bank_right"
          down_id="bank-left"
          up_id="bank-right"
          disabled={!@controls_enabled?}
        />
      </div>
      <button
        id="level-aircraft"
        type="button"
        phx-click="flight_command"
        phx-value-command="level"
        disabled={!@controls_enabled?}
        class={[
          "mt-3 inline-flex w-full items-center justify-center gap-2 rounded-xl border border-slate-200 bg-slate-50 px-4 py-3 text-xs font-bold text-slate-600 transition",
          if(@controls_enabled?,
            do: "cursor-pointer hover:border-cyan-300/25 hover:text-cyan-700",
            else: "cursor-not-allowed opacity-40"
          )
        ]}
      ><.icon name="hero-arrows-right-left" class={["size-4"]} /> Return pitch and bank to level</button>
    </section>
    """
  end

  attr :student, :map, required: true

  defp primary_flight_display(assigns) do
    horizon_transform =
      "transform: rotate(#{-assigns.student.flight.bank_deg}deg) translateY(#{assigns.student.flight.pitch_deg * 3}px)"

    heading =
      assigns.student.flight.heading_deg
      |> round()
      |> Integer.to_string()
      |> String.pad_leading(3, "0")

    assigns =
      assigns
      |> assign(:horizon_transform, horizon_transform)
      |> assign(:heading_display, heading)

    ~H"""
    <div
      id="primary-flight-display"
      class={[
        "mt-5 overflow-hidden rounded-3xl border border-slate-800 bg-[#08111f] p-4 text-white shadow-xl shadow-slate-300/50 sm:p-5"
      ]}
    >
      <div class={["mb-4 flex items-center justify-between"]}>
        <div>
          <p class={["text-[0.55rem] font-black uppercase tracking-[0.2em] text-cyan-300"]}>
            Primary flight display
          </p>
          <p class={["mt-1 text-xs text-slate-400"]}>Synthetic instrumentation · server telemetry</p>
        </div>
        <div class={[
          "flex items-center gap-2 text-[0.55rem] font-bold uppercase tracking-wider text-emerald-300"
        ]}>
          <span class={["size-1.5 rounded-full bg-emerald-300 shadow-[0_0_8px_rgba(110,231,183,0.6)]"]}></span>
          Data valid
        </div>
      </div>

      <div class={["grid items-center gap-4 lg:grid-cols-[0.65fr_1.15fr_0.65fr]"]}>
        <div class={["grid grid-cols-2 gap-2 lg:grid-cols-1"]}>
          <.instrument_readout
            id="airspeed-indicator"
            label="Airspeed"
            value={@student.flight.airspeed_kts}
            unit="KT"
            accent="cyan"
          />
          <.instrument_readout
            id="throttle-indicator"
            label="Throttle"
            value={@student.flight.throttle_percent}
            unit="%"
            accent="emerald"
          />
        </div>

        <div class={["relative mx-auto aspect-square w-full max-w-[22rem]"]}>
          <div
            id="artificial-horizon"
            class={[
              "absolute inset-0 overflow-hidden rounded-full border-[0.7rem] border-slate-700 bg-slate-900 shadow-[inset_0_0_0_1px_rgba(255,255,255,0.18),0_12px_35px_rgba(0,0,0,0.45)]"
            ]}
          >
            <div
              id="horizon-plane"
              class={["absolute -inset-[45%] transition-transform duration-200 ease-linear"]}
              style={@horizon_transform}
            >
              <div class={["h-1/2 bg-gradient-to-b from-sky-500 to-sky-300"]}></div>
              <div class={[
                "relative h-1/2 border-t-2 border-white bg-gradient-to-b from-amber-600 to-amber-900"
              ]}>
                <span class={["absolute inset-x-0 top-1 block h-px bg-black/30"]}></span>
              </div>
            </div>

            <div class={["pointer-events-none absolute inset-0"]}>
              <div class={["absolute left-1/2 top-[29%] h-px w-12 -translate-x-1/2 bg-white/80"]}>
              </div>
              <div class={["absolute left-1/2 top-[38%] h-px w-20 -translate-x-1/2 bg-white/80"]}>
              </div>
              <div class={[
                "absolute left-1/2 top-1/2 h-0.5 w-28 -translate-x-1/2 -translate-y-1/2 bg-white shadow-sm"
              ]}>
              </div>
              <div class={["absolute left-1/2 top-[62%] h-px w-20 -translate-x-1/2 bg-white/80"]}>
              </div>
              <div class={["absolute left-1/2 top-[71%] h-px w-12 -translate-x-1/2 bg-white/80"]}>
              </div>

              <div class={["absolute left-1/2 top-1/2 z-10 -translate-x-1/2 -translate-y-1/2"]}>
                <span class={["block h-1 w-11 -translate-x-8 rounded-full bg-amber-300 shadow"]}></span>
                <span class={[
                  "block h-1 w-11 translate-x-8 -translate-y-1 rounded-full bg-amber-300 shadow"
                ]}></span>
                <span class={[
                  "mx-auto -mt-1 block size-3 rotate-45 border-b-2 border-r-2 border-amber-300"
                ]}></span>
              </div>

              <div class={[
                "absolute inset-x-7 top-2 flex justify-between font-mono text-[0.55rem] font-bold text-white/75"
              ]}>
                <span>−30</span><span>0</span><span>+30</span>
              </div>
              <span class={[
                "absolute left-1/2 top-1 size-0 -translate-x-1/2 border-x-[5px] border-t-[8px] border-x-transparent border-t-amber-300"
              ]}></span>
              <div class={["absolute inset-x-0 bottom-3 flex justify-center"]}>
                <span
                  id="heading-indicator"
                  class={[
                    "rounded-md border border-white/20 bg-black/55 px-3 py-1 font-mono text-sm font-black text-emerald-300"
                  ]}
                >
                  HDG {@heading_display}°
                </span>
              </div>
            </div>
          </div>
        </div>

        <div class={["grid grid-cols-2 gap-2 lg:grid-cols-1"]}>
          <.instrument_readout
            id="altitude-indicator"
            label="Altitude"
            value={@student.flight.altitude_ft}
            unit="FT"
            accent="violet"
          />
          <.instrument_readout
            id="vertical-speed-indicator"
            label="Vertical speed"
            value={@student.flight.vertical_speed_fpm}
            unit="FPM"
            accent="amber"
          />
        </div>
      </div>

      <div class={["mt-4 grid grid-cols-2 gap-2 border-t border-white/10 pt-4 sm:grid-cols-4"]}>
        <.pfd_value label="Pitch" value={signed_value(@student.flight.pitch_deg, "°")} />
        <.pfd_value label="Bank" value={signed_value(@student.flight.bank_deg, "°")} />
        <.pfd_value label="Latitude" value={@student.flight.latitude} />
        <.pfd_value label="Longitude" value={@student.flight.longitude} />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, required: true
  attr :accent, :string, required: true

  defp instrument_readout(assigns) do
    ~H"""
    <div id={@id} class={["rounded-2xl border border-white/10 bg-white/[0.045] p-3"]}>
      <div class={["flex items-center justify-between gap-2"]}>
        <p class={["text-[0.5rem] font-black uppercase tracking-[0.16em] text-slate-400"]}>
          {@label}
        </p>
        <span class={["size-1.5 rounded-full", instrument_accent(@accent)]}></span>
      </div>
      <p class={["mt-2 font-mono text-2xl font-black tabular-nums text-white"]}>
        {@value}<span class={["ml-1 text-[0.55rem] text-slate-400"]}>{@unit}</span>
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp pfd_value(assigns) do
    ~H"""
    <div class={["text-center"]}>
      <p class={["text-[0.5rem] font-black uppercase tracking-[0.15em] text-slate-500"]}>{@label}</p>
      <p class={["mt-1 font-mono text-xs font-bold text-slate-200"]}>{@value}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, required: true
  attr :signed?, :boolean, default: false

  defp flight_metric(assigns) do
    display =
      if assigns.signed? and assigns.value > 0,
        do: "+#{assigns.value}",
        else: to_string(assigns.value)

    assigns = assign(assigns, :display, display)

    ~H"""
    <div id={@id} class={["rounded-2xl border border-slate-200 bg-slate-100/80 p-3"]}>
      <p class={["text-[0.55rem] font-black uppercase tracking-[0.15em] text-slate-500"]}>{@label}</p>
      <p class={["mt-2 font-mono text-xl font-black text-slate-950"]}>
        {@display}<span class={["ml-1 text-[0.6rem] text-slate-500"]}>{@unit}</span>
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :down, :string, required: true
  attr :up, :string, required: true
  attr :down_id, :string, required: true
  attr :up_id, :string, required: true
  attr :disabled, :boolean, required: true

  defp control_group(assigns) do
    ~H"""
    <div class={["rounded-2xl border border-slate-200 bg-slate-50 p-3"]}>
      <p class={[
        "mb-2 text-center text-[0.55rem] font-black uppercase tracking-[0.16em] text-slate-500"
      ]}>
        {@label}
      </p>
      <div class={["grid grid-cols-2 gap-2"]}>
        <button
          id={@down_id}
          type="button"
          phx-click="flight_command"
          phx-value-command={@down}
          disabled={@disabled}
          class={[
            "rounded-lg border border-slate-200 bg-slate-50 py-2 text-sm font-black text-slate-600 transition",
            if(@disabled,
              do: "cursor-not-allowed opacity-40",
              else: "cursor-pointer hover:border-violet-300/30 hover:text-violet-700"
            )
          ]}
        >−</button>
        <button
          id={@up_id}
          type="button"
          phx-click="flight_command"
          phx-value-command={@up}
          disabled={@disabled}
          class={[
            "rounded-lg border border-slate-200 bg-slate-50 py-2 text-sm font-black text-slate-600 transition",
            if(@disabled,
              do: "cursor-not-allowed opacity-40",
              else: "cursor-pointer hover:border-cyan-300/30 hover:text-cyan-700"
            )
          ]}
        >+</button>
      </div>
    </div>
    """
  end

  attr :streams, :map, required: true

  defp command_checklist(assigns) do
    ~H"""
    <section
      id="student-command-checklist"
      class={["rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-xl"]}
    >
      <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-violet-700"]}>
        Flight plan progress
      </p>
      <div id="command-progress" phx-update="stream" class={["mt-4 space-y-2"]}>
        <div
          :for={{dom_id, command} <- @streams.command_progress}
          id={dom_id}
          class={[
            "flex items-center gap-3 rounded-xl border p-3",
            command_status_class(command.status)
          ]}
        >
          <span class={["flex size-7 shrink-0 items-center justify-center rounded-lg bg-slate-100/80"]}><.icon
            name={command_status_icon(command.status)}
            class={["size-3.5"]}
          /></span>
          <div class={["min-w-0 flex-1"]}>
            <p class={["truncate text-xs font-bold text-slate-950"]}>{command.name}</p><p class={[
              "mt-0.5 text-[0.6rem] uppercase tracking-wider text-slate-500"
            ]}>
              {command.status}
            </p>
          </div>
          <span :if={command.attempts} class={["text-[0.6rem] text-slate-500"]}>{command.attempts} attempt{if(
            command.attempts == 1,
            do: "",
            else: "s"
          )}</span>
        </div>
      </div>
    </section>
    """
  end

  attr :streams, :map, required: true

  defp leaderboard(assigns) do
    ~H"""
    <section
      id="leaderboard-panel"
      class={["rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-xl"]}
    >
      <div class={["flex items-center justify-between"]}>
        <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-amber-700"]}>
          Leaderboard
        </p><.icon name="hero-trophy" class={["size-4 text-amber-700"]} />
      </div>
      <div id="leaderboard" phx-update="stream" class={["mt-4 space-y-2"]}>
        <div
          id="leaderboard-empty"
          class={[
            "hidden rounded-xl border border-dashed border-slate-200 p-5 text-center text-xs text-slate-500 only:block"
          ]}
        >
          Waiting for pilots
        </div>
        <div
          :for={{dom_id, student} <- @streams.leaderboard}
          id={dom_id}
          class={["flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 p-3"]}
        >
          <span class={[
            "flex size-8 items-center justify-center rounded-lg bg-amber-300/10 text-xs font-black text-amber-700"
          ]}>{student.name |> String.first() |> String.upcase()}</span>
          <div class={["min-w-0 flex-1"]}>
            <p class={["truncate text-xs font-bold text-slate-950"]}>{student.name}</p><p class={[
              "mt-0.5 text-[0.6rem] text-slate-500"
            ]}>
              {student.commands_judged} commands judged
            </p>
          </div>
          <span class={[
            "font-mono text-lg font-black",
            if(student.score > 0,
              do: "text-emerald-700",
              else: if(student.score < 0, do: "text-rose-700", else: "text-slate-500")
            )
          ]}>{if(student.score > 0, do: "+", else: "")}{student.score}</span>
        </div>
      </div>
    </section>
    """
  end

  attr :streams, :map, required: true
  attr :title, :string, required: true
  attr :instructor?, :boolean, required: true

  defp transcript(assigns) do
    ~H"""
    <section
      id="atc-transcript-panel"
      class={["rounded-3xl border border-slate-200 bg-slate-50/95 p-5 shadow-xl"]}
    >
      <div class={["flex items-center justify-between"]}>
        <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-cyan-700"]}>{@title}</p><span class={[
          "flex items-center gap-1.5 text-[0.55rem] uppercase tracking-wider text-emerald-700"
        ]}><span class={["size-1.5 animate-pulse rounded-full bg-emerald-300"]}></span> Live</span>
      </div>
      <div
        id="atc-transcript"
        phx-update="stream"
        class={["mt-4 max-h-64 space-y-2 overflow-y-auto pr-1"]}
      >
        <div
          id="transcript-empty"
          class={[
            "hidden rounded-xl border border-dashed border-slate-200 p-5 text-center text-xs text-slate-500 only:block"
          ]}
        >
          ATC frequency quiet
        </div>
        <div
          :for={{dom_id, message} <- @streams.transcript}
          id={dom_id}
          class={["rounded-xl border border-slate-100 bg-slate-50 p-3"]}
        >
          <p class={[
            "text-[0.55rem] font-black uppercase tracking-[0.15em]",
            message_kind_class(message.kind)
          ]}>
            ATC<%= if @instructor? do %>
              → {message.student_name}
            <% end %>
          </p>
          <p class={["mt-1 text-xs leading-5 text-slate-700"]}>{message.text}</p>
        </div>
      </div>
    </section>
    """
  end

  attr :streams, :map, required: true
  attr :snapshot, :map, required: true

  defp instructor_progress(assigns) do
    ~H"""
    <section
      id="student-progress-panel"
      class={["rounded-3xl border border-slate-200 bg-white/90 p-5 shadow-xl"]}
    >
      <div class={["flex items-center justify-between"]}>
        <div>
          <p class={["text-[0.65rem] font-black uppercase tracking-[0.2em] text-violet-700"]}>
            Student progress
          </p><h3 class={["mt-1 text-lg font-black text-slate-950"]}>
            {length(@snapshot.students)} independent aircraft
          </h3>
        </div><.icon name="hero-users" class={["size-5 text-violet-700"]} />
      </div>
      <div id="student-progress" phx-update="stream" class={["mt-5 grid gap-3 md:grid-cols-2"]}>
        <div
          :for={{dom_id, student} <- @streams.student_progress}
          id={dom_id}
          class={["rounded-2xl border border-slate-200 bg-slate-100/80 p-4"]}
        >
          <div class={["flex items-start justify-between gap-3"]}>
            <div>
              <p class={["text-sm font-black text-slate-950"]}>{student.name}</p><p class={[
                "mt-1 text-[0.6rem] uppercase tracking-wider text-slate-500"
              ]}>
                {if(student.completed?,
                  do: "Lesson complete",
                  else: "Command #{student.command_number} · attempt #{student.attempt}"
                )}
              </p>
            </div><span class={["font-mono text-xl font-black text-amber-700"]}>{if(student.score > 0,
              do: "+",
              else: ""
            )}{student.score}</span>
          </div>
          <div
            :if={student.current_command}
            class={["mt-4 rounded-xl border border-cyan-300/10 bg-cyan-300/[0.04] p-3"]}
          >
            <p class={["text-[0.55rem] font-black uppercase tracking-[0.15em] text-cyan-700"]}>
              Current command
            </p><p class={["mt-1 text-xs font-bold text-slate-950"]}>
              {student.current_command.instruction}
            </p><p class={["mt-2 font-mono text-[0.65rem] text-slate-500"]}>
              {Float.ceil(student.attempt_remaining_ms / 1_000, 1)}s remaining
            </p>
          </div>
          <div class={["mt-3 grid grid-cols-3 gap-2 text-center"]}>
            <.mini_metric label="Throttle" value={"#{student.flight.throttle_percent}%"} /><.mini_metric
              label="Pitch"
              value={"#{student.flight.pitch_deg}°"}
            /><.mini_metric label="Bank" value={"#{student.flight.bank_deg}°"} />
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp mini_metric(assigns) do
    ~H"""
    <div class={["rounded-lg bg-slate-50 p-2"]}>
      <p class={["text-[0.5rem] uppercase tracking-wider text-slate-500"]}>{@label}</p>
      <p class={["mt-1 font-mono text-xs font-bold text-slate-700"]}>{@value}</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp status_stat(assigns) do
    ~H"""
    <div class={["min-w-20 rounded-xl border border-slate-200 bg-slate-100/80 px-3 py-2"]}>
      <p class={["text-[0.5rem] font-black uppercase tracking-wider text-slate-500"]}>{@label}</p>
      <p class={["mt-1 font-mono text-sm font-black text-slate-950"]}>{@value}</p>
    </div>
    """
  end

  attr :streams, :map, required: true

  defp presence_panel(assigns) do
    ~H"""
    <section
      id="classroom-roster-panel"
      class={["rounded-3xl border border-slate-200 bg-white/85 p-5"]}
    >
      <div class={["grid gap-5 md:grid-cols-2"]}>
        <div>
          <p class={["text-[0.6rem] font-black uppercase tracking-[0.18em] text-amber-700"]}>
            Instructor online
          </p><div id="classroom-instructors" phx-update="stream" class={["mt-3 space-y-2"]}>
            <div
              id="instructor-empty"
              class={[
                "hidden rounded-xl border border-dashed border-slate-200 p-3 text-xs text-slate-500 only:block"
              ]}
            >
              Instructor reconnecting
            </div><div
              :for={{dom_id, person} <- @streams.instructors}
              id={dom_id}
              class={[
                "flex items-center gap-3 rounded-xl border border-amber-300/10 bg-amber-300/[0.04] p-3"
              ]}
            >
              <span class={["size-2 rounded-full bg-emerald-300"]}></span><p class={[
                "text-xs font-bold text-slate-950"
              ]}>
                {person.name}
              </p>
            </div>
          </div>
        </div>
        <div>
          <p class={["text-[0.6rem] font-black uppercase tracking-[0.18em] text-violet-700"]}>
            Students online
          </p><div id="classroom-students" phx-update="stream" class={["mt-3 flex flex-wrap gap-2"]}>
            <div
              id="students-empty"
              class={[
                "hidden rounded-xl border border-dashed border-slate-200 p-3 text-xs text-slate-500 only:block"
              ]}
            >
              Waiting for students
            </div><div
              :for={{dom_id, person} <- @streams.students}
              id={dom_id}
              class={[
                "inline-flex items-center gap-2 rounded-xl border border-violet-300/10 bg-violet-300/[0.04] px-3 py-2"
              ]}
            >
              <span class={["size-1.5 rounded-full bg-emerald-300"]}></span><p class={[
                "text-xs font-bold text-slate-950"
              ]}>
                {person.name}
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp status_label(:waiting), do: "waiting"
  defp status_label(:running), do: "in progress"
  defp status_label(:paused), do: "paused"
  defp status_label(:completed), do: "completed"

  defp status_class(:waiting), do: "border-cyan-300/20 bg-cyan-300/10 text-cyan-700"
  defp status_class(:running), do: "border-emerald-300/30 bg-emerald-300/15 text-emerald-700"
  defp status_class(:paused), do: "border-amber-300/20 bg-amber-300/10 text-amber-700"
  defp status_class(:completed), do: "border-violet-300/20 bg-violet-300/10 text-violet-700"

  defp command_status_class(:active), do: "border-cyan-300/25 bg-cyan-300/[0.06] text-cyan-700"

  defp command_status_class(:completed),
    do: "border-emerald-300/20 bg-emerald-300/[0.05] text-emerald-700"

  defp command_status_class(:failed), do: "border-rose-300/20 bg-rose-300/[0.05] text-rose-700"
  defp command_status_class(:pending), do: "border-slate-200 bg-slate-50 text-slate-500"

  defp command_status_icon(:active), do: "hero-radio"
  defp command_status_icon(:completed), do: "hero-check"
  defp command_status_icon(:failed), do: "hero-x-mark"
  defp command_status_icon(:pending), do: "hero-minus"

  defp message_kind_class(:completed), do: "text-emerald-700"
  defp message_kind_class(:lesson_completed), do: "text-emerald-700"
  defp message_kind_class(:failed), do: "text-rose-700"
  defp message_kind_class(:retry), do: "text-amber-700"
  defp message_kind_class(_kind), do: "text-cyan-700"

  defp instrument_accent("cyan"), do: "bg-cyan-300"
  defp instrument_accent("emerald"), do: "bg-emerald-300"
  defp instrument_accent("violet"), do: "bg-violet-300"
  defp instrument_accent("amber"), do: "bg-amber-300"

  defp signed_value(value, unit) when value > 0, do: "+#{value}#{unit}"
  defp signed_value(value, unit), do: "#{value}#{unit}"
end
