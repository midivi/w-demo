defmodule Wail.Classrooms.LessonEngine do
  @moduledoc "Pure command timing, evaluation, transcript, and scoring logic."

  alias Wail.Classrooms.LessonCommand
  alias Wail.Classrooms.LessonPlan
  alias Wail.Classrooms.StudentSession

  @transcript_limit 50

  def start(%StudentSession{} = student, %LessonPlan{} = plan, config) do
    student
    |> reset(config)
    |> issue_current(plan, :instruction)
  end

  def reset(%StudentSession{} = student, config) do
    %{
      student
      | score: 0,
        command_index: 0,
        attempt: 1,
        attempt_remaining_ms: config.attempt_duration_ms,
        hold_elapsed_ms: 0,
        target_acquired?: false,
        results: [],
        transcript: [],
        completed?: false,
        next_message_id: 1
    }
  end

  def advance(%StudentSession{completed?: true} = student, _plan, _config, _elapsed_ms),
    do: student

  def advance(%StudentSession{} = student, %LessonPlan{} = plan, config, elapsed_ms)
      when is_integer(elapsed_ms) and elapsed_ms > 0 do
    command = current_command(student, plan)
    evaluated_ms = min(elapsed_ms, student.attempt_remaining_ms)
    target_met? = LessonCommand.target_met?(command, student.flight)

    hold_elapsed_ms =
      if target_met?, do: student.hold_elapsed_ms + evaluated_ms, else: 0

    student = %{
      student
      | attempt_remaining_ms: max(student.attempt_remaining_ms - elapsed_ms, 0),
        hold_elapsed_ms: hold_elapsed_ms,
        target_acquired?: target_met?
    }

    cond do
      hold_elapsed_ms >= config.hold_duration_ms ->
        complete_command(student, plan, config, command)

      student.attempt_remaining_ms == 0 ->
        expire_attempt(student, plan, config, command)

      true ->
        student
    end
  end

  def advance(%StudentSession{} = student, _plan, _config, _elapsed_ms), do: student

  def current_command(%StudentSession{} = student, %LessonPlan{} = plan) do
    Enum.at(plan.commands, student.command_index)
  end

  defp complete_command(student, plan, config, command) do
    result = %{command_id: command.id, status: :completed, score: 1, attempts: student.attempt}

    student
    |> Map.update!(:score, &(&1 + 1))
    |> Map.update!(:results, &(&1 ++ [result]))
    |> append_message(:completed, "Roger. Command “#{command.name}” completed.")
    |> advance_command(plan, config)
  end

  defp expire_attempt(student, _plan, config, command)
       when student.attempt < config.maximum_attempts do
    next_attempt = student.attempt + 1

    student
    |> Map.merge(%{
      attempt: next_attempt,
      attempt_remaining_ms: config.attempt_duration_ms,
      hold_elapsed_ms: 0,
      target_acquired?: false
    })
    |> append_message(
      :retry,
      "Say again. #{command.instruction} Attempt #{next_attempt} of #{config.maximum_attempts}."
    )
  end

  defp expire_attempt(student, plan, config, command) do
    result = %{command_id: command.id, status: :failed, score: -1, attempts: student.attempt}

    student
    |> Map.update!(:score, &(&1 - 1))
    |> Map.update!(:results, &(&1 ++ [result]))
    |> append_message(:failed, "Command “#{command.name}” not completed. Proceeding.")
    |> advance_command(plan, config)
  end

  defp advance_command(student, plan, config) do
    next_index = student.command_index + 1

    if next_index >= length(plan.commands) do
      student
      |> Map.merge(%{
        command_index: next_index,
        attempt_remaining_ms: 0,
        hold_elapsed_ms: 0,
        target_acquired?: false,
        completed?: true
      })
      |> append_message(:lesson_completed, "Lesson complete. Maintain present course.")
    else
      student
      |> Map.merge(%{
        command_index: next_index,
        attempt: 1,
        attempt_remaining_ms: config.attempt_duration_ms,
        hold_elapsed_ms: 0,
        target_acquired?: false
      })
      |> issue_current(plan, :instruction)
    end
  end

  defp issue_current(student, plan, kind) do
    command = current_command(student, plan)
    append_message(student, kind, command.instruction)
  end

  defp append_message(student, kind, text) do
    message = %{
      id: "#{student.id}:#{student.next_message_id}",
      kind: kind,
      text: text,
      sequence: student.next_message_id
    }

    transcript = Enum.take(student.transcript ++ [message], -@transcript_limit)
    %{student | transcript: transcript, next_message_id: student.next_message_id + 1}
  end
end
