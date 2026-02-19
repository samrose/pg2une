import Config

config :pg2une, ecto_repos: [Pg2une.Repo]

# mxc configuration — runs embedded in standalone mode for microVM orchestration
config :mxc,
  ecto_repos: [Mxc.Repo],
  mode: :standalone,
  ui_enabled: false,
  start_agent: true,
  cluster_strategy: :gossip,
  scheduler_strategy: :spread

config :mxc, MxcWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: MxcWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mxc.PubSub,
  live_view: [signing_salt: "pg2une_mxc"],
  server: false

# Disable swoosh API client — pg2une doesn't use email
config :swoosh, :api_client, false

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
