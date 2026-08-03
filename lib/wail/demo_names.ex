defmodule Wail.DemoNames do
  @moduledoc "Generates friendly anonymous student callsigns for the demo lobby."

  @names ~w(
    Ada Aisha Alex Amara Amir Ana Andre Anika Aria Arun Ava Ben Bianca Bruno Camila
    Carmen Celeste Chen Chloe Clara Daniel Dario David Diego Elena Elias Ella Emil Emma
    Eva Fatima Felix Finn Freya Gabriel Grace Hana Harper Hugo Ibrahim Imani Ines Iris
    Ivan Jade Jamal Jamie Javier Jia Joel Jonas Julia Kai Karim Keira Kenji Lara Leo
    Lina Luca Lucia Luis Maja Marco Maria Mateo Maya Mia Mila Mina Nadia Naomi Nico Nina
    Noah Noor Nora Omar Oscar Priya Rafael Ravi Rosa Ruby Sam Sara Sofia Sora Theo Tom
    Valentina Victor Wei Yara Yasmin Yuki Zoe Zuri Aiden Alba
  )

  @animals ~w(Bear Eagle Falcon Fox Lynx Otter Owl Panda Raven Wolf)

  def generate do
    "#{random(@names)} #{random(@animals)}"
  end

  def name_count, do: length(@names)
  def animal_count, do: length(@animals)

  defp random(values) do
    values
    |> Enum.at(:rand.uniform(length(values)) - 1)
  end
end
