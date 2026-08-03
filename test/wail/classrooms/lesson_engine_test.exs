defmodule Wail.Classrooms.LessonEngineTest do
  use ExUnit.Case, async: true

  alias Wail.Classrooms.LessonEngine
  alias Wail.Classrooms.LessonPlan
  alias Wail.Classrooms.StudentSession

  @config %{attempt_duration_ms: 1_000, maximum_attempts: 3, hold_duration_ms: 2_000}

  setup do
    plan = LessonPlan.default()
    student = StudentSession.new(%{id: "student-1", display_name: "Sam"}, 1_000)
    %{plan: plan, student: LessonEngine.start(student, plan, @config)}
  end

  test "requires the target continuously for the configured hold", %{plan: plan, student: student} do
    student = put_in(student.flight.throttle_percent, 65.0)
    student = LessonEngine.advance(student, plan, @config, 900)
    assert student.hold_elapsed_ms == 900
    assert student.command_index == 0

    student = %{student | attempt_remaining_ms: 1_000}
    student = put_in(student.flight.throttle_percent, 55.0)
    student = LessonEngine.advance(student, plan, @config, 250)
    assert student.hold_elapsed_ms == 0

    student = %{student | attempt_remaining_ms: 3_000}
    student = put_in(student.flight.throttle_percent, 65.0)
    student = LessonEngine.advance(student, plan, @config, 2_000)

    assert student.score == 1
    assert student.command_index == 1
    assert List.first(student.results).status == :completed
    assert Enum.any?(student.transcript, &(&1.kind == :completed))
  end

  test "repeats twice and penalizes the third failed attempt", %{plan: plan, student: student} do
    student = LessonEngine.advance(student, plan, @config, 1_000)
    assert student.attempt == 2
    assert student.score == 0

    student = LessonEngine.advance(student, plan, @config, 1_000)
    assert student.attempt == 3
    assert student.score == 0

    student = LessonEngine.advance(student, plan, @config, 1_000)
    assert student.score == -1
    assert student.command_index == 1
    assert List.first(student.results).status == :failed
    assert Enum.count(student.transcript, &(&1.kind == :retry)) == 2
  end

  test "completes a lesson after its final command", %{plan: plan, student: student} do
    student = %{student | command_index: length(plan.commands) - 1, attempt_remaining_ms: 3_000}
    student = put_in(student.flight.throttle_percent, 50.0)
    student = LessonEngine.advance(student, plan, @config, 2_000)

    assert student.completed?
    assert student.score == 1
    assert List.last(student.transcript).kind == :lesson_completed
  end
end
