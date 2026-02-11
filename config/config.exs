import Config

config :pgtune, ecto_repos: [Pgtune.Repo]

import_config "#{config_env()}.exs"
