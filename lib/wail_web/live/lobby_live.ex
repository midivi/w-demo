defmodule WailWeb.LobbyLive do
  use WailWeb, :live_view

  alias Wail.Classrooms
  alias Wail.DemoNames
  alias WailWeb.ClassroomAccess

  @impl true
  def mount(params, session, socket) do
    room_id = params |> Map.get("room_id", "") |> Classrooms.normalize_room_id()
    lessons = Classrooms.list_active_lessons()
    student_name = DemoNames.generate()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Wail.PubSub, Classrooms.lobby_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Flight classroom")
     |> assign(:guest_id, Map.fetch!(session, "guest_id"))
     |> assign(:create_form, to_form(%{"name" => ""}, as: :create))
     |> assign(:join_form, to_form(%{"name" => student_name, "room_id" => room_id}, as: :join))
     |> assign(:active_join_form, to_form(%{"name" => student_name}, as: :active_join))
     |> assign(:lesson_count, length(lessons))
     |> stream(:lessons, lessons)}
  end

  @impl true
  def handle_params(%{"room_id" => room_id}, _uri, socket) do
    params = %{"name" => socket.assigns.join_form[:name].value || "", "room_id" => room_id}
    {:noreply, assign(socket, :join_form, to_form(params, as: :join))}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("create_room", %{"create" => params}, socket) do
    with {:ok, display_name} <- validate_name(params["name"]),
         {:ok, room} <-
           Classrooms.create_room(socket.assigns.guest_id, instructor_name: display_name) do
      token =
        ClassroomAccess.sign(
          room.room_id,
          socket.assigns.guest_id,
          display_name,
          :instructor
        )

      {:noreply, push_navigate(socket, to: ~p"/rooms/#{room.room_id}?access=#{token}")}
    else
      {:error, :invalid_name} ->
        {:noreply,
         socket
         |> assign(:create_form, to_form(params, as: :create))
         |> put_flash(:error, "Enter a display name between 2 and 30 characters.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The classroom could not be created.")}
    end
  end

  def handle_event("join_room", %{"join" => params}, socket) do
    room_id = Classrooms.normalize_room_id(params["room_id"] || "")

    with {:ok, display_name} <- validate_name(params["name"]),
         true <- Classrooms.room_exists?(room_id) do
      token =
        ClassroomAccess.sign(room_id, socket.assigns.guest_id, display_name, :student)

      {:noreply, push_navigate(socket, to: ~p"/rooms/#{room_id}?access=#{token}")}
    else
      {:error, :invalid_name} ->
        {:noreply,
         socket
         |> assign(:join_form, to_form(params, as: :join))
         |> put_flash(:error, "Enter a display name between 2 and 30 characters.")}

      false ->
        {:noreply,
         socket
         |> assign(:join_form, to_form(params, as: :join))
         |> put_flash(:error, "That classroom is not active. Check the room code and try again.")}
    end
  end

  def handle_event("join_active", %{"active_join" => params}, socket) do
    room_id = Classrooms.normalize_room_id(params["room_id"] || "")

    with {:ok, display_name} <- validate_name(params["name"]),
         {:ok, listing} <- Classrooms.listing(room_id),
         true <- listing.joinable? do
      token = ClassroomAccess.sign(room_id, socket.assigns.guest_id, display_name, :student)
      {:noreply, push_navigate(socket, to: ~p"/rooms/#{room_id}?access=#{token}")}
    else
      {:error, :invalid_name} ->
        {:noreply,
         socket
         |> assign(:active_join_form, to_form(params, as: :active_join))
         |> put_flash(:error, "Enter a display name between 2 and 30 characters.")}

      _not_joinable ->
        {:noreply, put_flash(socket, :error, "That lesson is no longer accepting students.")}
    end
  end

  @impl true
  def handle_info({:classroom_listing_changed, _room_id}, socket) do
    lessons = Classrooms.list_active_lessons()

    {:noreply,
     socket
     |> assign(:lesson_count, length(lessons))
     |> stream(:lessons, lessons, reset: true)}
  end

  defp validate_name(name) when is_binary(name) do
    name = String.trim(name)

    if String.length(name) in 2..30 do
      {:ok, name}
    else
      {:error, :invalid_name}
    end
  end

  defp validate_name(_name), do: {:error, :invalid_name}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={assigns[:current_scope]}>
      <div
        id="lobby"
        class={[
          "relative mx-auto grid min-h-[calc(100vh-7rem)] max-w-7xl items-center gap-12 py-10 lg:grid-cols-[1.15fr_0.85fr] lg:py-16"
        ]}
      >
        <section class={["relative"]}>
          <div class={[
            "mb-8 inline-flex items-center gap-2 rounded-full border border-cyan-300/20 bg-cyan-300/5 px-3 py-1.5 text-xs font-bold uppercase tracking-[0.18em] text-cyan-700"
          ]}>
            <span class={["size-1.5 animate-pulse rounded-full bg-cyan-300"]}></span>
            Phoenix classroom prototype
          </div>
          <h1 class={[
            "max-w-3xl text-5xl font-black leading-[0.95] tracking-[-0.05em] text-slate-950 sm:text-6xl lg:text-7xl"
          ]}>
            One aircraft.<br />Every screen.<br /><span class={["text-cyan-700"]}>No peer mesh.</span>
          </h1>
          <p class={["mt-7 max-w-2xl text-base leading-7 text-slate-500 sm:text-lg"]}>
            A server-authoritative flight classroom built to show how LiveView, GenServer,
            PubSub, and Presence replace browser-to-browser coordination with one clear system.
          </p>

          <div class={["mt-10 grid max-w-2xl gap-3 sm:grid-cols-3"]}>
            <.architecture_badge icon="hero-command-line" title="GenServer" body="Owns the aircraft" />
            <.architecture_badge icon="hero-signal" title="PubSub" body="Fans out telemetry" />
            <.architecture_badge icon="hero-user-group" title="Presence" body="Tracks the roster" />
          </div>
        </section>

        <section class={[
          "relative overflow-hidden rounded-3xl border border-slate-200 bg-white/90 p-2 shadow-2xl shadow-slate-300/50 backdrop-blur"
        ]}>
          <div class={["rounded-[1.25rem] border border-slate-100 bg-slate-50/95 p-6 sm:p-8"]}>
            <div class={["mb-7 flex items-center justify-between"]}>
              <div>
                <p class={["text-xs font-bold uppercase tracking-[0.18em] text-cyan-700"]}>
                  Flight operations
                </p>
                <h2 class={["mt-2 text-2xl font-bold text-slate-950"]}>Start or join a session</h2>
              </div>
              <div class={[
                "flex size-12 items-center justify-center rounded-2xl border border-slate-200 bg-slate-50 text-slate-500"
              ]}>
                <.icon name="hero-paper-airplane" class={["size-5 -rotate-45"]} />
              </div>
            </div>

            <div class={["space-y-7"]}>
              <.form for={@create_form} id="create-room-form" phx-submit="create_room">
                <.input
                  field={@create_form[:name]}
                  type="text"
                  label="Instructor display name"
                  placeholder="e.g. Captain Noor"
                  autocomplete="name"
                  class={[
                    "w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-950 outline-none transition placeholder:text-slate-400 focus:border-cyan-300/60 focus:ring-2 focus:ring-cyan-300/10"
                  ]}
                />
                <button
                  id="create-room-button"
                  type="submit"
                  class={[
                    "mt-3 inline-flex w-full cursor-pointer items-center justify-center gap-2 rounded-xl bg-cyan-300 px-4 py-3 text-sm font-extrabold text-slate-950 transition hover:-translate-y-0.5 hover:bg-cyan-200 active:translate-y-0 phx-submit-loading:pointer-events-none phx-submit-loading:opacity-60"
                  ]}
                >
                  Create a classroom <.icon name="hero-arrow-right" class={["size-4"]} />
                </button>
              </.form>

              <div class={["flex items-center gap-4"]}>
                <span class={["h-px flex-1 bg-white/10"]}></span>
                <span class={["text-[0.65rem] font-bold uppercase tracking-[0.2em] text-slate-500"]}>or join a crew</span>
                <span class={["h-px flex-1 bg-white/10"]}></span>
              </div>

              <.form for={@join_form} id="join-room-form" phx-submit="join_room">
                <div class={["grid gap-3 sm:grid-cols-2"]}>
                  <.input
                    field={@join_form[:name]}
                    type="text"
                    label="Student display name"
                    placeholder="e.g. Sam"
                    autocomplete="name"
                    class={[
                      "w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-950 outline-none transition placeholder:text-slate-400 focus:border-cyan-300/60 focus:ring-2 focus:ring-cyan-300/10"
                    ]}
                  />
                  <.input
                    field={@join_form[:room_id]}
                    type="text"
                    label="Room code"
                    placeholder="SIM-XXXXXX"
                    autocomplete="off"
                    class={[
                      "w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-3 font-mono text-sm uppercase text-slate-950 outline-none transition placeholder:text-slate-400 focus:border-cyan-300/60 focus:ring-2 focus:ring-cyan-300/10"
                    ]}
                  />
                </div>
                <button
                  id="join-room-button"
                  type="submit"
                  class={[
                    "mt-3 inline-flex w-full cursor-pointer items-center justify-center gap-2 rounded-xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm font-bold text-slate-950 transition hover:-translate-y-0.5 hover:border-cyan-300/30 hover:bg-cyan-300/10 active:translate-y-0 phx-submit-loading:pointer-events-none phx-submit-loading:opacity-60"
                  ]}
                >
                  Join as observer <.icon name="hero-arrow-right" class={["size-4"]} />
                </button>
              </.form>
            </div>
          </div>
        </section>

        <section
          id="active-lessons-panel"
          class={[
            "lg:col-span-2 rounded-3xl border border-slate-200 bg-white/90 p-6 shadow-2xl shadow-slate-300/40 sm:p-8"
          ]}
        >
          <div class={[
            "flex flex-col gap-5 border-b border-slate-200 pb-6 sm:flex-row sm:items-end sm:justify-between"
          ]}>
            <div>
              <p class={["text-xs font-bold uppercase tracking-[0.2em] text-violet-700"]}>
                Active lessons
              </p>
              <h2 class={["mt-2 text-2xl font-black tracking-tight text-slate-950"]}>
                Join a live flight classroom
              </h2>
              <p class={["mt-2 max-w-2xl text-sm leading-6 text-slate-500"]}>
                Waiting lessons accept new pilots. Running and paused sessions remain visible so everyone can see what is underway.
              </p>
            </div>
            <span
              id="active-lesson-count"
              class={[
                "inline-flex w-fit items-center gap-2 rounded-xl border border-violet-300/20 bg-violet-300/10 px-3 py-2 text-xs font-bold text-violet-700"
              ]}
            >
              <span class={["size-1.5 rounded-full bg-violet-300"]}></span>
              {@lesson_count} active
            </span>
          </div>

          <.form
            for={@active_join_form}
            id="active-lesson-join-form"
            phx-submit="join_active"
            class={["mt-6"]}
          >
            <div class={["mb-5 max-w-sm"]}>
              <.input
                field={@active_join_form[:name]}
                type="text"
                label="Your student name"
                placeholder="e.g. Victor"
                autocomplete="name"
                class={[
                  "w-full rounded-xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-950 outline-none transition placeholder:text-slate-400 focus:border-violet-300/60 focus:ring-2 focus:ring-violet-300/10"
                ]}
              />
            </div>

            <div id="active-lessons" phx-update="stream" class={["grid gap-4 lg:grid-cols-2"]}>
              <div
                id="active-lessons-empty"
                class={[
                  "hidden rounded-2xl border border-dashed border-slate-200 p-10 text-center only:block lg:col-span-2"
                ]}
              >
                <.icon name="hero-radio" class={["mx-auto size-7 text-slate-700"]} />
                <p class={["mt-3 text-sm font-bold text-slate-500"]}>No classrooms on frequency</p>
                <p class={["mt-1 text-xs text-slate-500"]}>Create one above to begin the demo.</p>
              </div>

              <article
                :for={{dom_id, lesson} <- @streams.lessons}
                id={dom_id}
                class={[
                  "group rounded-2xl border p-5 transition",
                  if(lesson.joinable?,
                    do: "border-cyan-300/15 bg-cyan-300/[0.035] hover:border-cyan-300/30",
                    else: "border-slate-200 bg-slate-100/80"
                  )
                ]}
              >
                <div class={["flex items-start justify-between gap-4"]}>
                  <div class={["min-w-0"]}>
                    <div class={["flex flex-wrap items-center gap-2"]}>
                      <span class={[
                        "rounded-full border px-2 py-1 text-[0.55rem] font-black uppercase tracking-[0.16em]",
                        lesson_status_class(lesson.status)
                      ]}>
                        {lesson_status_label(lesson.status)}
                      </span>
                      <span class={["font-mono text-[0.65rem] text-slate-500"]}>{lesson.room_id}</span>
                    </div>
                    <h3 class={["mt-3 truncate text-base font-black text-slate-950"]}>
                      {lesson.plan_name}
                    </h3>
                    <p class={["mt-1 text-xs text-slate-500"]}>Led by {lesson.instructor_name}</p>
                  </div>
                  <span class={[
                    "flex size-10 shrink-0 items-center justify-center rounded-xl border border-slate-200 bg-slate-50 text-slate-500"
                  ]}>
                    <.icon name="hero-paper-airplane" class={["size-4 -rotate-45"]} />
                  </span>
                </div>

                <p class={["mt-4 line-clamp-2 text-xs leading-5 text-slate-500"]}>
                  {lesson.plan_description}
                </p>

                <div class={["mt-4 flex flex-wrap gap-2 text-[0.65rem] text-slate-500"]}>
                  <span class={["rounded-lg border border-slate-200 bg-slate-50 px-2.5 py-1.5"]}>
                    {lesson.enrolled_count} pilot{if(lesson.enrolled_count == 1, do: "", else: "s")}
                  </span>
                  <span class={["rounded-lg border border-slate-200 bg-slate-50 px-2.5 py-1.5"]}>
                    {lesson.attempt_duration_seconds}s · {lesson.maximum_attempts} attempts
                  </span>
                </div>

                <button
                  id={"join-active-#{lesson.room_id}"}
                  type="submit"
                  name="active_join[room_id]"
                  value={lesson.room_id}
                  disabled={!lesson.joinable?}
                  class={[
                    "mt-5 inline-flex w-full items-center justify-center gap-2 rounded-xl px-4 py-2.5 text-xs font-extrabold transition",
                    if(lesson.joinable?,
                      do:
                        "cursor-pointer bg-cyan-300 text-slate-950 hover:-translate-y-0.5 hover:bg-cyan-200",
                      else: "cursor-not-allowed border border-slate-200 bg-slate-50 text-slate-500"
                    )
                  ]}
                >
                  <%= if lesson.joinable? do %>
                    Join lesson <.icon name="hero-arrow-right" class={["size-3.5"]} />
                  <% else %>
                    {lesson_status_label(lesson.status)}
                  <% end %>
                </button>
              </article>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  defp architecture_badge(assigns) do
    ~H"""
    <div class={["rounded-2xl border border-slate-200 bg-white/80 p-4 shadow-sm"]}>
      <.icon name={@icon} class={["size-4 text-cyan-700"]} />
      <p class={["mt-3 text-sm font-bold text-slate-950"]}>{@title}</p>
      <p class={["mt-1 text-xs text-slate-500"]}>{@body}</p>
    </div>
    """
  end

  defp lesson_status_label(:waiting), do: "Waiting"
  defp lesson_status_label(:running), do: "In progress"
  defp lesson_status_label(:paused), do: "Paused"
  defp lesson_status_label(:completed), do: "Completed"

  defp lesson_status_class(:waiting), do: "border-cyan-300/20 bg-cyan-300/10 text-cyan-700"

  defp lesson_status_class(:running),
    do: "border-emerald-300/30 bg-emerald-300/15 text-emerald-700"

  defp lesson_status_class(:paused), do: "border-amber-300/20 bg-amber-300/10 text-amber-700"
  defp lesson_status_class(:completed), do: "border-slate-200 bg-slate-50 text-slate-500"
end
