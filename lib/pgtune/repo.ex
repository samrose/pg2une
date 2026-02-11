defmodule Pgtune.Repo do
  use Ecto.Repo, otp_app: :pgtune, adapter: Ecto.Adapters.Postgres
end
