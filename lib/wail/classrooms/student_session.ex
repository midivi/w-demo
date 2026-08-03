defmodule Wail.Classrooms.StudentSession do
  @moduledoc "Server-owned flight and ATC progress for one enrolled student."

  alias Wail.Classrooms.FlightModel

  @enforce_keys [:id, :name]
  defstruct id: nil,
            name: nil,
            flight: nil,
            score: 0,
            command_index: 0,
            attempt: 1,
            attempt_remaining_ms: 0,
            hold_elapsed_ms: 0,
            target_acquired?: false,
            results: [],
            transcript: [],
            completed?: false,
            next_message_id: 1

  def new(%{id: id, display_name: name}, attempt_duration_ms) do
    %__MODULE__{
      id: id,
      name: name,
      flight: FlightModel.new(),
      attempt_remaining_ms: attempt_duration_ms
    }
  end
end
