use Mix.Config

alias Datagouvfr.Authentication

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :transport, TransportWeb.Endpoint,
  http: [port: 5001],
  server: true

# Integration testing with Hound
# See docs at:
# * https://github.com/HashNuke/hound/blob/master/notes/configuring-hound.md
# * https://github.com/HashNuke/hound/wiki/Starting-a-webdriver-server
config :hound, driver: "selenium", browser: "chrome"

# Print only warnings and errors during test on screen, but still allow to
# capture info logs during tests
# https://elixirforum.com/t/exunit-capturelog-assert-capture-log-2-not-capturing-level-info/8617/10?u=thbar
config :logger, level: :info
config :logger, :console, level: :warn

# Configure data.gouv.fr authentication
config :oauth2, Authentication,
  site: "https://demo.data.gouv.fr"

# Validator configuration
config :transport, gtfs_validator_url: System.get_env("GTFS_VALIDATOR_URL") || "http://127.0.0.1:7878"

config :exvcr, [
  vcr_cassette_library_dir: "test/fixture/cassettes",
  filter_request_headers: ["authorization"]
]

config :db, DB.Repo,
  url: System.get_env("PG_URL_TEST") || System.get_env("PG_URL") || "ecto://postgres:postgres@localhost/transport_test",
  pool: Ecto.Adapters.SQL.Sandbox
