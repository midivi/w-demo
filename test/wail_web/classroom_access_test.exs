defmodule WailWeb.ClassroomAccessTest do
  use ExUnit.Case, async: true

  alias WailWeb.ClassroomAccess

  test "round-trips an instructor capability" do
    token = ClassroomAccess.sign("sim-abc123", "guest-1", "Captain Noor", :instructor)

    assert ClassroomAccess.verify(token, "SIM-ABC123", "guest-1") ==
             {:ok, %{id: "guest-1", display_name: "Captain Noor", role: :instructor}}
  end

  test "rejects a token for another room or browser identity" do
    token = ClassroomAccess.sign("SIM-ABC123", "guest-1", "Sam", :student)

    assert ClassroomAccess.verify(token, "SIM-WRONG1", "guest-1") ==
             {:error, :invalid_access}

    assert ClassroomAccess.verify(token, "SIM-ABC123", "guest-2") ==
             {:error, :invalid_access}
  end

  test "gives each student join a distinct presence identity" do
    first_token = ClassroomAccess.sign("SIM-ABC123", "shared-browser", "Sam", :student)
    second_token = ClassroomAccess.sign("SIM-ABC123", "shared-browser", "Alex", :student)

    assert {:ok, first} = ClassroomAccess.verify(first_token, "SIM-ABC123", "shared-browser")
    assert {:ok, second} = ClassroomAccess.verify(second_token, "SIM-ABC123", "shared-browser")

    assert first.id != "shared-browser"
    assert second.id != "shared-browser"
    assert first.id != second.id
  end

  test "rejects missing and tampered tokens" do
    token = ClassroomAccess.sign("SIM-ABC123", "guest-1", "Sam", :student)

    assert ClassroomAccess.verify(nil, "SIM-ABC123", "guest-1") ==
             {:error, :invalid_access}

    assert ClassroomAccess.verify(token <> "tampered", "SIM-ABC123", "guest-1") ==
             {:error, :invalid_access}
  end
end
