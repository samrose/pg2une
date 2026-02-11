import Config

if config_env() == :prod do
  config :pgtune, Pgtune.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :pgtune,
    target_url: System.fetch_env!("TARGET_POSTGRES_URL"),
    mxc_coordinator: System.get_env("MXC_COORDINATOR", "http://localhost:4000")
end
