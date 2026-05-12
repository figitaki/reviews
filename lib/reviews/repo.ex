defmodule Reviews.Repo do
  use Ecto.Repo,
    otp_app: :reviews,
    adapter: Ecto.Adapters.Postgres
end
