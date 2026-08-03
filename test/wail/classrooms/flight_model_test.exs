defmodule Wail.Classrooms.FlightModelTest do
  use ExUnit.Case, async: true

  alias Wail.Classrooms.FlightModel

  test "throttle, pitch, and bank drive deterministic movement" do
    initial = FlightModel.new()

    assert {:ok, controlled} = FlightModel.apply_command(initial, {:adjust, :throttle, 20})
    assert {:ok, controlled} = FlightModel.apply_command(controlled, {:adjust, :pitch, 4})
    assert {:ok, controlled} = FlightModel.apply_command(controlled, {:adjust, :bank, 12})

    advanced = FlightModel.advance(controlled, 1.0)

    assert advanced.airspeed_kts > initial.airspeed_kts
    assert advanced.vertical_speed_fpm > 0
    assert advanced.altitude_ft > initial.altitude_ft
    assert advanced.heading_deg > initial.heading_deg
    assert advanced.latitude != initial.latitude
    assert advanced.longitude != initial.longitude
  end

  test "controls are clamped and level returns pitch and bank to zero" do
    state = FlightModel.new()

    assert {:ok, state} = FlightModel.apply_command(state, {:adjust, :throttle, 1_000})
    assert {:ok, state} = FlightModel.apply_command(state, {:adjust, :pitch, -1_000})
    assert {:ok, state} = FlightModel.apply_command(state, {:adjust, :bank, 1_000})
    assert state.throttle_percent == 100.0
    assert state.pitch_deg == -10.0
    assert state.bank_deg == 30.0

    assert {:ok, level} = FlightModel.apply_command(state, :level)
    assert level.pitch_deg == 0.0
    assert level.bank_deg == 0.0
  end

  test "paused models do not advance and reset restores the initial snapshot" do
    initial = FlightModel.new()
    assert {:ok, paused} = FlightModel.apply_command(initial, :toggle_pause)
    assert FlightModel.advance(paused, 10.0) == paused

    assert {:ok, reset} = FlightModel.apply_command(paused, :reset)
    assert reset == initial
  end

  test "unknown commands are rejected" do
    assert FlightModel.apply_command(FlightModel.new(), {:warp, 9}) ==
             {:error, :unsupported_command}
  end
end
