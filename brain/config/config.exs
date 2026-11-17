import Config

config :handmedown, env: config_env()

config :logger, level: :warning

if config_env() == :test do
  config :logger, level: :error
end
