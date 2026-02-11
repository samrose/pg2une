import Config

config :pgtune, Pgtune.Repo,
  database: "pgtune_dev",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10
