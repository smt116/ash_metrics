import Config

config :ash_metrics, prefix: "test", otp_app: :ash_metrics

config :ash_metrics, ash_domains: [AshMetrics.Test.Mailings, AshMetrics.Test.Queue]

# Required by Ash to compile the resources in `test/support`.
config :ash, default_string_length_count: :codepoints
