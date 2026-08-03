defmodule Wail.Repo do
  use Ecto.Repo,
    otp_app: :wail,
    adapter: Ecto.Adapters.Postgres
end
