import Config

config :pgtune, Pgtune.Repo,
  database: "pgtune_test#{System.get_env("MIX_TEST_PARTITION")}",
  socket_dir: "/tmp",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Configure mxc's Repo so it doesn't crash on startup (transitive dep)
config :mxc, Mxc.Repo,
  database: "pgtune_test#{System.get_env("MIX_TEST_PARTITION")}",
  socket_dir: "/tmp",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 2

# mxc mode: standalone avoids distributed cluster setup
config :mxc, mode: :standalone

# Disable swoosh (transitive dep from mxc) in test
config :swoosh, :api_client, false
