defmodule Wail.Classrooms.LessonPlan do
  @moduledoc "The built-in ATC lesson catalog used by the demo."

  alias Wail.Classrooms.LessonCommand

  @enforce_keys [:id, :name, :description, :commands]
  defstruct [:id, :name, :description, :commands]

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          description: String.t(),
          commands: [LessonCommand.t()]
        }

  def list do
    [
      %__MODULE__{
        id: :basic_controls,
        name: "Basic aircraft control",
        description:
          "A short introduction to throttle, bank, and returning the aircraft to level flight.",
        commands: [
          %LessonCommand{
            id: :throttle_65,
            name: "Throttle 65%",
            instruction: "Set throttle to 65 percent.",
            metric: :throttle_percent,
            minimum: 62,
            maximum: 68,
            unit: "%"
          },
          %LessonCommand{
            id: :bank_right_15,
            name: "Bank Right 15°",
            instruction: "Bank right to 15 degrees.",
            metric: :bank_deg,
            minimum: 12,
            maximum: 18,
            unit: "°"
          },
          %LessonCommand{
            id: :wings_level,
            name: "Wings Level",
            instruction: "Return the aircraft to wings level.",
            metric: :bank_deg,
            minimum: -3,
            maximum: 3,
            unit: "°"
          },
          %LessonCommand{
            id: :throttle_50,
            name: "Throttle 50%",
            instruction: "Reduce throttle to 50 percent.",
            metric: :throttle_percent,
            minimum: 47,
            maximum: 53,
            unit: "%"
          }
        ]
      },
      %__MODULE__{
        id: :right_turns,
        name: "Right turns",
        description: "Practice establishing and recovering from medium and steep right banks.",
        commands: [
          %LessonCommand{
            id: :bank_right_21,
            name: "Bank Right 21°",
            instruction: "Bank right to 21 degrees.",
            metric: :bank_deg,
            minimum: 18,
            maximum: 24,
            unit: "°"
          },
          %LessonCommand{
            id: :wings_level_one,
            name: "Wings Level",
            instruction: "Return the aircraft to wings level.",
            metric: :bank_deg,
            minimum: -3,
            maximum: 3,
            unit: "°"
          },
          %LessonCommand{
            id: :bank_right_27,
            name: "Bank Right 27°",
            instruction: "Increase the right bank to 27 degrees.",
            metric: :bank_deg,
            minimum: 24,
            maximum: 30,
            unit: "°"
          },
          %LessonCommand{
            id: :wings_level_two,
            name: "Wings Level",
            instruction: "Recover to wings level.",
            metric: :bank_deg,
            minimum: -3,
            maximum: 3,
            unit: "°"
          },
          %LessonCommand{
            id: :throttle_60,
            name: "Throttle 60%",
            instruction: "Set throttle to 60 percent.",
            metric: :throttle_percent,
            minimum: 57,
            maximum: 63,
            unit: "%"
          }
        ]
      },
      %__MODULE__{
        id: :left_turns,
        name: "Left turns",
        description: "Build confidence entering and recovering from left-bank attitudes.",
        commands: [
          %LessonCommand{
            id: :bank_left_18,
            name: "Bank Left 18°",
            instruction: "Bank left to 18 degrees.",
            metric: :bank_deg,
            minimum: -21,
            maximum: -15,
            unit: "°"
          },
          %LessonCommand{
            id: :wings_level_one,
            name: "Wings Level",
            instruction: "Return the aircraft to wings level.",
            metric: :bank_deg,
            minimum: -3,
            maximum: 3,
            unit: "°"
          },
          %LessonCommand{
            id: :bank_left_27,
            name: "Bank Left 27°",
            instruction: "Increase the left bank to 27 degrees.",
            metric: :bank_deg,
            minimum: -30,
            maximum: -24,
            unit: "°"
          },
          %LessonCommand{
            id: :wings_level_two,
            name: "Wings Level",
            instruction: "Recover to wings level.",
            metric: :bank_deg,
            minimum: -3,
            maximum: 3,
            unit: "°"
          },
          %LessonCommand{
            id: :throttle_55,
            name: "Throttle 55%",
            instruction: "Set throttle to 55 percent.",
            metric: :throttle_percent,
            minimum: 52,
            maximum: 58,
            unit: "%"
          }
        ]
      },
      %__MODULE__{
        id: :climb_procedure,
        name: "Climb procedure",
        description: "Configure climb power, establish a positive pitch, then return to cruise.",
        commands: [
          %LessonCommand{
            id: :throttle_75,
            name: "Throttle 75%",
            instruction: "Increase throttle to 75 percent.",
            metric: :throttle_percent,
            minimum: 72,
            maximum: 78,
            unit: "%"
          },
          %LessonCommand{
            id: :pitch_up_6,
            name: "Pitch Up 6°",
            instruction: "Pitch up to 6 degrees.",
            metric: :pitch_deg,
            minimum: 5,
            maximum: 7,
            unit: "°"
          },
          %LessonCommand{
            id: :positive_climb,
            name: "Positive Climb",
            instruction: "Establish a climb between 1,000 and 1,800 feet per minute.",
            metric: :vertical_speed_fpm,
            minimum: 1_000,
            maximum: 1_800,
            unit: " fpm"
          },
          %LessonCommand{
            id: :pitch_level,
            name: "Pitch Level",
            instruction: "Return pitch to level flight.",
            metric: :pitch_deg,
            minimum: -1,
            maximum: 1,
            unit: "°"
          },
          %LessonCommand{
            id: :throttle_60,
            name: "Throttle 60%",
            instruction: "Reduce throttle to 60 percent.",
            metric: :throttle_percent,
            minimum: 57,
            maximum: 63,
            unit: "%"
          }
        ]
      },
      %__MODULE__{
        id: :combined_sequence,
        name: "Combined flight sequence",
        description: "Combine power, pitch, and bank changes in a compact multi-axis exercise.",
        commands: [
          %LessonCommand{
            id: :throttle_80,
            name: "Throttle 80%",
            instruction: "Increase throttle to 80 percent.",
            metric: :throttle_percent,
            minimum: 77,
            maximum: 83,
            unit: "%"
          },
          %LessonCommand{
            id: :pitch_up_5,
            name: "Pitch Up 5°",
            instruction: "Pitch up to 5 degrees.",
            metric: :pitch_deg,
            minimum: 4,
            maximum: 6,
            unit: "°"
          },
          %LessonCommand{
            id: :bank_right_15,
            name: "Bank Right 15°",
            instruction: "Bank right to 15 degrees.",
            metric: :bank_deg,
            minimum: 12,
            maximum: 18,
            unit: "°"
          },
          %LessonCommand{
            id: :wings_level,
            name: "Wings Level",
            instruction: "Return the aircraft to wings level.",
            metric: :bank_deg,
            minimum: -3,
            maximum: 3,
            unit: "°"
          },
          %LessonCommand{
            id: :pitch_level,
            name: "Pitch Level",
            instruction: "Return pitch to level flight.",
            metric: :pitch_deg,
            minimum: -1,
            maximum: 1,
            unit: "°"
          },
          %LessonCommand{
            id: :throttle_55,
            name: "Throttle 55%",
            instruction: "Reduce throttle to 55 percent.",
            metric: :throttle_percent,
            minimum: 52,
            maximum: 58,
            unit: "%"
          }
        ]
      }
    ]
  end

  def default, do: list() |> hd()

  def fetch(id) when is_atom(id), do: list() |> Enum.find(&(&1.id == id)) |> result()

  def fetch(id) when is_binary(id) do
    list() |> Enum.find(&(Atom.to_string(&1.id) == id)) |> result()
  end

  def fetch(_id), do: {:error, :unknown_lesson_plan}

  defp result(nil), do: {:error, :unknown_lesson_plan}
  defp result(plan), do: {:ok, plan}
end
