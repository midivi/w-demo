defmodule Wail.DemoNamesTest do
  use ExUnit.Case, async: true

  alias Wail.DemoNames

  test "generates a two-part callsign from the configured pools" do
    assert DemoNames.name_count() == 100
    assert DemoNames.animal_count() == 10
    assert [first_name, animal] = String.split(DemoNames.generate())
    assert first_name != ""
    assert animal != ""
  end
end
