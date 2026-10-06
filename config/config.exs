import Config

Path.wildcard("config/local/*.exs")
  |> Enum.each( fn file -> "local/" <> (file |> Path.basename()) |> import_config() end )
  
