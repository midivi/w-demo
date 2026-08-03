defmodule Wail.Classrooms.Supervisor do
  @moduledoc "Dynamically supervises one classroom process per active room."

  use DynamicSupervisor

  alias Wail.Classrooms.ClassroomServer

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_room(opts) do
    DynamicSupervisor.start_child(__MODULE__, {ClassroomServer, opts})
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
