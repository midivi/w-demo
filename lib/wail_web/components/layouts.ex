defmodule WailWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use WailWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class={["min-h-screen bg-[#f4f7fb] text-slate-700"]}>
      <div class={["pointer-events-none fixed inset-0 overflow-hidden"]}>
        <div class={[
          "absolute -left-48 -top-48 size-[34rem] rounded-full bg-cyan-400/[0.10] blur-3xl"
        ]}>
        </div>
        <div class={[
          "absolute -bottom-64 -right-48 size-[38rem] rounded-full bg-violet-400/[0.08] blur-3xl"
        ]}>
        </div>
      </div>

      <header class={[
        "relative z-10 border-b border-slate-200/80 bg-white/85 px-4 shadow-sm backdrop-blur sm:px-6 lg:px-8"
      ]}>
        <div class={["mx-auto flex h-16 max-w-[96rem] items-center justify-between"]}>
          <.link navigate={~p"/"} class={["flex items-center gap-3"]}>
            <span class={[
              "flex size-9 items-center justify-center rounded-xl border border-cyan-600/20 bg-cyan-600/10 text-cyan-700"
            ]}>
              <.icon name="hero-paper-airplane" class={["size-4 -rotate-45"]} />
            </span>
            <span>
              <span class={["block text-xs font-black tracking-[0.18em] text-slate-950"]}>WAIL</span>
              <span class={[
                "block text-[0.55rem] font-semibold uppercase tracking-[0.16em] text-slate-500"
              ]}>Flight classroom</span>
            </span>
          </.link>
          <div class={[
            "flex items-center gap-2 text-[0.6rem] font-bold uppercase tracking-[0.16em] text-slate-500"
          ]}>
            <span class={[
              "size-1.5 rounded-full bg-emerald-500 shadow-[0_0_8px_rgba(16,185,129,0.35)]"
            ]}></span>
            Phoenix online
          </div>
        </div>
      </header>

      <main class={["relative z-0 px-4 sm:px-6 lg:px-8"]}>
        {render_slot(@inner_block)}
      </main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
