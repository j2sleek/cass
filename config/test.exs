import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cass, Cass.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cass_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cass, CassWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "rYN1U2KDUTYV5rBiPZzaNu6oq7wPO8FVeLwHEIzQhw61z4K9B15c0dga43ZQwHqU",
  server: false

# In test we don't send emails
config :cass, Cass.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Paystack adapter for the test environment: a dummy secret (never a real key)
# and `:req_options` that route every adapter HTTP request through `Req.Test`,
# so tests stub responses with `Req.Test.stub(:paystack, ...)` and nothing ever
# leaves the test process.
config :cass, :paystack,
  secret_key: "sk_test_dummy_dummy_dummy_dummy_dummy_dummy",
  req_options: [plug: {Req.Test, :paystack}]

# The delivery access-signing secret for tests: a fixed dummy, so a derived
# access code is deterministic within a run and no test needs a real key. Only
# `Cass.DeliverySecretTest` replaces this value, and it does so serially.
config :cass, Cass.Delivery, access_secret: "test_dummy_delivery_access_secret_not_a_real_key"

# The AI gateway adapter for the test environment: a dummy key (never a real
# one) and `:req_options` that route every adapter HTTP request through
# `Req.Test`, so tests stub responses with `Req.Test.stub(:nexus_ai, ...)` and
# nothing ever leaves the test process. The registry entry below is what makes
# `Cass.Ai.available?/0` true, so the buyer's run form is exercisable here.
config :cass, :nexus_ai,
  api_key: "nx_test_dummy_dummy_dummy_dummy_dummy",
  base_url: "http://nexus.test",
  model: "default",
  req_options: [plug: {Req.Test, :nexus_ai}]

config :cass, Cass.Ai,
  gateways: [
    nexus: [module: Cass.Ai.Gateways.Nexus, enabled: true]
  ],
  # A deliberately small window so the rate-limit test is fast and stays
  # predictable rather than depending on wall-clock timing.
  rate_limit: [max_runs: 3, window_seconds: 60]
