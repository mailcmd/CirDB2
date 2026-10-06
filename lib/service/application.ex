defmodule CirDB.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    CirDB.init()
    children = [{Plug.Cowboy, scheme: :http, plug: CirDB.Endpoint, options: [port: port()]}]
    opts = [strategy: :one_for_one, name: CirDB.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    CirDB.stop()
  end

  defp port, do: Application.get_env(:cir_db, :config)[:port] || 9666
end
