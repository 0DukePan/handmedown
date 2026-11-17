import Config

# Runtime configuration: the release cannot read the build environment, so anything machine-specific
# is resolved here.
if config_env() != :test do
  config :handmedown,
    port: String.to_integer(System.get_env("HAND_PORT") || "4100"),
    data_dir: System.get_env("HAND_DATA") || ".hand"

  # The join token is what makes "enrol this device" a decision rather than an accident. Generated on
  # first boot and written to the data directory, so restarting the brain does not invalidate every
  # device on the network.
  config :handmedown, token: System.get_env("HAND_TOKEN")
end
