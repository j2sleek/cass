defmodule Cass.Repo do
  use Ecto.Repo,
    otp_app: :cass,
    adapter: Ecto.Adapters.Postgres
end
