import Config

if config_env() == :prod do
  config :pg2une, Pg2une.Repo,
    url: System.fetch_env!("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :pg2une,
    target_url: System.fetch_env!("TARGET_POSTGRES_URL"),
    mxc_coordinator: System.get_env("MXC_COORDINATOR", "http://localhost:4000")
end
