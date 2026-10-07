# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Password hashing for `Cass.Accounts`. PBKDF2-HMAC-SHA512 with 160_000 rounds,
# which is in line with the OWASP recommendation for PBKDF2-HMAC-SHA512
# (210_000). `config/test.exs` lowers the cost for the test suite only.
# See docs/security.md for the full rationale.
config :pbkdf2_elixir, rounds: 160_000

# The authentication scope used by `CassWeb.UserAuth`. Roles/authorization
# fields are deliberately absent in Milestone 3 Phase 1: the scope only carries
# the resolved user, and it is resolved server-side, never from the request.
config :cass, :scopes,
  user: [
    default: true,
    module: Cass.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :cass_users,
    test_data_fixture: Cass.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :cass,
  ecto_repos: [Cass.Repo],
  generators: [timestamp_type: :utc_datetime],
  environment: config_env(),
  # Auth cookies (session + "remember me") are only marked `secure` in
  # production, where the endpoint forces HTTPS. Overridden in config/prod.exs.
  secure_cookies: false

# Paystack adapter defaults. `:secret_key` is deliberately absent here: it is
# a runtime secret injected per environment (dummy in dev/test, `PAYSTACK_SECRET_KEY`
# in prod via `config/runtime.exs`). Tests swap in `:req_options` to route all
# adapter HTTP through `Req.Test`.
config :cass, :paystack, base_url: "https://api.paystack.co"

# The secret used to derive the access code a buyer receives for a delivered
# purchase (`Cass.Delivery`). Like the payment secret it is deliberately absent
# here and injected per environment: a dummy in dev/test, `DELIVERY_ACCESS_SECRET`
# in prod via `config/runtime.exs`. It is a *signing* key — it never leaves the
# server, and nothing derived from it is reversible.
config :cass, Cass.Delivery, access_secret: nil

# The registry of payment provider adapters (`Cass.Payments.Providers`).
# Enabling a provider here (with its adapter module) is the only step needed
# to make it usable by `Cass.Payments`. Provider-specific secrets live under
# their own key (`:cass, :paystack`) so they can be injected at runtime per
# environment without touching this shared file.
config :cass, Cass.Payments,
  providers: [
    paystack: [module: Cass.Payments.Providers.Paystack, enabled: true]
  ]

# Configure the endpoint
config :cass, CassWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CassWeb.ErrorHTML, json: CassWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cass.PubSub,
  live_view: [signing_salt: "cFKZv60B"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :cass, Cass.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  cass: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  cass: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Background job queue for automated delivery.
#
# Two queues, because they have different urgency: `fulfillment` carries the work
# a buyer is waiting on, `sweep` carries the periodic repair pass that re-enqueues
# deliveries abandoned by a dead worker.
config :cass, Oban,
  repo: Cass.Repo,
  queues: [fulfillment: 10, sweep: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Cass.Fulfillment.RecoverySweep}
     ]},
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]

# How long a `:processing` delivery may sit untouched before the sweep treats it
# as abandoned. Deliberately much larger than `Cass.Fulfillment.Worker.timeout/1`
# (60s): a premature reclaim costs two workers on one row, while a delivery that
# never runs at all costs a customer who paid and got nothing.
config :cass, Cass.Fulfillment, abandoned_after_seconds: 900

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
