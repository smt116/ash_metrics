import Config

config :spark, formatter: [remove_parens?: true]

# Only the test environment ships a config file; dev and prod are configured by
# the host application that depends on this package.
if File.exists?(Path.join(__DIR__, "#{config_env()}.exs")) do
  import_config "#{config_env()}.exs"
end
