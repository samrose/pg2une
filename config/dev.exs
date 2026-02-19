import Config

config :pg2une, Pg2une.Repo,
  database: "pg2une_dev",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Target PostgreSQL to tune (the local instance itself for dev/demo)
config :pg2une,
  target_url: "postgres://samrose:@localhost:5432/postgres",
  poll_interval: 15_000,
  port: 4080

# mxc uses the same local PostgreSQL for its workload state
config :mxc, Mxc.Repo,
  database: "mxc_dev",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 5

config :mxc, MxcWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  check_origin: false,
  secret_key_base: "pg2une_mxc_dev_secret_key_base_that_is_at_least_64_bytes_long_for_phoenix",
  watchers: []
