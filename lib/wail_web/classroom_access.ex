defmodule WailWeb.ClassroomAccess do
  @moduledoc "Signs and verifies temporary classroom capabilities."

  alias Wail.Classrooms

  @salt "classroom-access-v1"
  @max_age :timer.hours(24) |> div(1_000)

  def sign(room_id, guest_id, display_name, role) when role in [:instructor, :student] do
    participant_id = participant_id(role, guest_id)

    Phoenix.Token.sign(WailWeb.Endpoint, @salt, %{
      "room_id" => Classrooms.normalize_room_id(room_id),
      "guest_id" => guest_id,
      "participant_id" => participant_id,
      "display_name" => display_name,
      "role" => Atom.to_string(role)
    })
  end

  def verify(token, room_id, guest_id) when is_binary(token) do
    expected_room_id = Classrooms.normalize_room_id(room_id)

    with {:ok, claims} <-
           Phoenix.Token.verify(WailWeb.Endpoint, @salt, token, max_age: @max_age),
         %{
           "room_id" => ^expected_room_id,
           "guest_id" => ^guest_id,
           "participant_id" => participant_id,
           "display_name" => display_name,
           "role" => role
         } <- claims,
         {:ok, role} <- parse_role(role) do
      {:ok, %{id: participant_id, display_name: display_name, role: role}}
    else
      _other -> {:error, :invalid_access}
    end
  end

  def verify(_token, _room_id, _guest_id), do: {:error, :invalid_access}

  defp parse_role("instructor"), do: {:ok, :instructor}
  defp parse_role("student"), do: {:ok, :student}
  defp parse_role(_role), do: {:error, :invalid_role}

  defp participant_id(:instructor, guest_id), do: guest_id

  defp participant_id(:student, _guest_id) do
    suffix =
      12
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    "student-#{suffix}"
  end
end
