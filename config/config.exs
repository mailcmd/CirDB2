import Config

config :cir_db, service: [
  port: System.get_env("CIRDB_SERVICE_PORT", "9666") |> Integer.parse() |> elem(0)
]
