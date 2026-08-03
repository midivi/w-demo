# Wail Flight Classroom

A small Phoenix demonstration of a server-authoritative ATC flight classroom.
An instructor selects a lesson plan, students join from a live lobby, and every
student receives an independent fake aircraft owned by the room process.

The demo deliberately keeps the flight model simple so the Phoenix architecture
is easy to see:

- one `ClassroomServer` GenServer per active room
- `DynamicSupervisor` and `Registry` for room lifecycle and lookup
- a deterministic ATC lesson engine for targets, timers, retries, and scoring
- five built-in lesson plans with configurable attempt timing
- Phoenix.PubSub for 4 Hz aircraft telemetry and live lobby status
- Phoenix.Presence for the connected roster
- LiveView for the lobby, instructor console, ATC transcript, and cockpits
- signed guest capabilities for role and per-student aircraft authorization

Rooms live in memory and shut down after being empty for ten minutes. The
database is part of the generated Phoenix application but is not used to store
classrooms or telemetry.

## Run the demo

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

To exercise the full flow:

1. Enter an instructor name and create a classroom.
2. Select one of the five lesson plans and configure the attempt duration and count.
3. Open the lobby in another browser, enter a student name, and join the waiting lesson.
4. Enroll additional students, then start the lesson from the instructor console.
5. Follow the ATC commands from each independent student cockpit.
6. Watch retries, transcripts, command progress, and the shared leaderboard update live.
7. Use the instructor controls to pause, continue, or reset the lesson.

Run the complete project check with `mix precommit`.

## Deploy to Fly.io

The included `fly.toml` targets one always-on `shared-cpu-1x` Machine with 1 GB
of memory in Amsterdam (`ams`). Classroom state is local to that single VM.

1. Change the `app` value in `fly.toml` if `wail-atc-classroom` is unavailable.
2. Create the Fly app with `fly apps create <app-name>`.
3. Set the release secret with `fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)`.
4. Deploy one Machine with `fly deploy --ha=false`.

No Postgres cluster or `DATABASE_URL` is required. If the Machine restarts or is
replaced, all active classrooms are intentionally lost.

## Intentional limitations

- no real WASM flight simulator or map engine
- no database-backed users or rooms
- no custom browser Channel alongside LiveView
- no room recovery after an application restart
- no enrollment after a lesson has started; enrolled students may reconnect
- no audio or speech synthesis for ATC messages
- illustrative rather than realistic flight dynamics
