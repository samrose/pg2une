import Config

config :pg2une, ecto_repos: [Pg2une.Repo]

import_config "#{config_env()}.exs"
