import Config

config :cir_db, config: [
  port: System.get_env("CIRDB_SERVICE_PORT", "9666") |> Integer.parse() |> elem(0),
  dir: "/var/cir_db",
  cache_dir: "/dev/shm/cir_db_chache",
  time_offset: -10800,
  sync_every: 300,            # seconds
  purge_every: 86400,         # seconds
  purge_older_than: 90*86400, # seconds
  rrdtool_binary: "/usr/bin/rrdtool"
]
