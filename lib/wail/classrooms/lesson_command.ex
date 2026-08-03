defmodule Wail.Classrooms.LessonCommand do
  @moduledoc "A single range-based ATC instruction in a lesson plan."

  @enforce_keys [:id, :name, :instruction, :metric, :minimum, :maximum]
  defstruct [:id, :name, :instruction, :metric, :minimum, :maximum, unit: ""]

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          instruction: String.t(),
          metric: atom(),
          minimum: number(),
          maximum: number(),
          unit: String.t()
        }

  def target_met?(%__MODULE__{} = command, flight) when is_map(flight) do
    case Map.fetch(flight, command.metric) do
      {:ok, value} when is_number(value) ->
        value >= command.minimum and value <= command.maximum

      _other ->
        false
    end
  end

  def target_label(%__MODULE__{} = command) do
    "#{format(command.minimum)}–#{format(command.maximum)}#{command.unit}"
  end

  defp format(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 0)
  defp format(value), do: to_string(value)
end
