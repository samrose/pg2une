import Config

config :pg2une, Pg2une.Repo,
  database: "pg2une_dev",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
