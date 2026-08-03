defmodule Wail.Classrooms.FlightModel do
  @moduledoc """
  A deterministic teaching model used to make server-owned room state visible.

  It is intentionally illustrative rather than aerodynamically accurate.
  """

  @initial_state %{
    latitude: 52.3086,
    longitude: 4.7639,
    altitude_ft: 2_400.0,
    airspeed_kts: 112.0,
    heading_deg: 90.0,
    vertical_speed_fpm: 0.0,
    throttle_percent: 55.0,
    pitch_deg: 0.0,
    bank_deg: 0.0,
    elapsed_seconds: 0.0,
    running?: true
  }

  def new, do: @initial_state

  def apply_command(state, {:adjust, :throttle, amount}) when is_number(amount) do
    {:ok, Map.update!(state, :throttle_percent, &clamp(&1 + amount, 0.0, 100.0))}
  end

  def apply_command(state, {:adjust, :pitch, amount}) when is_number(amount) do
    {:ok, Map.update!(state, :pitch_deg, &clamp(&1 + amount, -10.0, 10.0))}
  end

  def apply_command(state, {:adjust, :bank, amount}) when is_number(amount) do
    {:ok, Map.update!(state, :bank_deg, &clamp(&1 + amount, -30.0, 30.0))}
  end

  def apply_command(state, :level) do
    {:ok, %{state | pitch_deg: 0.0, bank_deg: 0.0}}
  end

  def apply_command(state, :toggle_pause) do
    {:ok, Map.update!(state, :running?, &(!&1))}
  end

  def apply_command(_state, :reset), do: {:ok, new()}
  def apply_command(_state, _command), do: {:error, :unsupported_command}

  def advance(%{running?: false} = state, _seconds), do: state

  def advance(state, seconds) when is_number(seconds) and seconds > 0 do
    target_airspeed = 60.0 + state.throttle_percent * 1.35
    airspeed = approach(state.airspeed_kts, target_airspeed, 7.0 * seconds)
    target_vertical_speed = state.pitch_deg * 260.0
    vertical_speed = approach(state.vertical_speed_fpm, target_vertical_speed, 600.0 * seconds)
    altitude = max(0.0, state.altitude_ft + vertical_speed / 60.0 * seconds)
    heading = normalize_heading(state.heading_deg + state.bank_deg * 0.16 * seconds)
    distance_nm = airspeed * seconds / 3_600.0
    heading_radians = degrees_to_radians(heading)
    latitude = state.latitude + distance_nm * :math.cos(heading_radians) / 60.0

    longitude =
      state.longitude +
        distance_nm * :math.sin(heading_radians) /
          (60.0 * max(:math.cos(degrees_to_radians(state.latitude)), 0.01))

    %{
      state
      | altitude_ft: altitude,
        airspeed_kts: airspeed,
        heading_deg: heading,
        vertical_speed_fpm: vertical_speed,
        latitude: latitude,
        longitude: longitude,
        elapsed_seconds: state.elapsed_seconds + seconds
    }
  end

  def display_snapshot(state) do
    %{
      altitude_ft: round(state.altitude_ft),
      airspeed_kts: round(state.airspeed_kts),
      heading_deg: state.heading_deg |> round() |> rem(360),
      vertical_speed_fpm: round(state.vertical_speed_fpm),
      throttle_percent: round(state.throttle_percent),
      pitch_deg: Float.round(state.pitch_deg, 1),
      bank_deg: Float.round(state.bank_deg, 1),
      latitude: Float.round(state.latitude, 5),
      longitude: Float.round(state.longitude, 5),
      elapsed_seconds: Float.round(state.elapsed_seconds, 1),
      running?: state.running?
    }
  end

  defp approach(value, target, maximum_change) do
    cond do
      value < target -> min(value + maximum_change, target)
      value > target -> max(value - maximum_change, target)
      true -> value
    end
  end

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)

  defp normalize_heading(heading) when heading >= 360.0, do: heading - 360.0
  defp normalize_heading(heading) when heading < 0.0, do: heading + 360.0
  defp normalize_heading(heading), do: heading

  defp degrees_to_radians(degrees), do: degrees * :math.pi() / 180.0
end
