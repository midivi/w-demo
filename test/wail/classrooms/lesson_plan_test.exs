defmodule Wail.Classrooms.LessonPlanTest do
  use ExUnit.Case, async: true

  alias Wail.Classrooms.LessonCommand
  alias Wail.Classrooms.LessonPlan

  test "ships five valid example lesson plans" do
    plans = LessonPlan.list()

    assert length(plans) == 5

    assert Enum.map(plans, & &1.id) == [
             :basic_controls,
             :right_turns,
             :left_turns,
             :climb_procedure,
             :combined_sequence
           ]

    assert Enum.all?(plans, &(&1.commands != []))

    assert Enum.all?(plans, fn plan ->
             Enum.all?(plan.commands, fn command ->
               command.minimum < command.maximum and command.instruction != ""
             end)
           end)
  end

  test "looks plans up without converting user input to atoms" do
    assert {:ok, plan} = LessonPlan.fetch("combined_sequence")
    assert plan.id == :combined_sequence
    assert LessonPlan.fetch("missing") == {:error, :unknown_lesson_plan}
  end

  test "evaluates command targets from flight telemetry" do
    command = %LessonCommand{
      id: :bank,
      name: "Bank",
      instruction: "Bank right.",
      metric: :bank_deg,
      minimum: 12,
      maximum: 18,
      unit: "°"
    }

    assert LessonCommand.target_met?(command, %{bank_deg: 15})
    refute LessonCommand.target_met?(command, %{bank_deg: 9})
    assert LessonCommand.target_label(command) == "12–18°"
  end
end
