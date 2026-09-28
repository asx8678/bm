defmodule Bm.Repo do
  use Ecto.Repo,
    otp_app: :bm,
    adapter: Ecto.Adapters.Postgres
end
