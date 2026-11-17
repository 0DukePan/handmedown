import Config

config :handmedown, env: config_env()

config :handmedown,
  # Where the job/shard snapshot lives. Relative to the working directory so `hand up` from a
  # project directory keeps its state with the project.
  data_dir: ".hand",
  port: 4100,
  beat_ms: 5_000,
  lease_ms: 30_000,
  sweep_ms: 5_000,
  max_attempts: 3

config :logger, level: :warning

if config_env() == :test do
  config :logger, level: :error
  config :handmedown, data_dir: nil
  # Tests drive the scheduler directly; binding a port in every test run would make them flaky and
  # impossible to run in parallel.
  config :handmedown, start_server: false, token: "test-token"
end
