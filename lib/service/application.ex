defmodule CirDB.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do

    children =
      if CirDB.MixProject.get_mode() == :service do
        CirDB.init()
        [
          {Plug.Cowboy, scheme: :http, plug: CirDB.Endpoint, options: [port: port()]}
        ]
      else
        []
      end
    # ++
    # if Application.get_env(:chart_service, :ssl_enabled) do
    #   [
    #     {Plug.Cowboy, scheme: :https, plug: ChartService.Endpoint, options: [
    #       otp_app: :chart_service,
    #       port: ssl_port(),
    #       certfile: Application.get_env(:chart_service, :ssl_certfile),
    #       keyfile: Application.get_env(:chart_service, :ssl_keyfile),
    #       cacertfile: Application.get_env(:chart_service, :ssl_cacertfile)
    #     ]}
    #   ]
    # else
    #   []
    # end

    opts = [strategy: :one_for_one, name: CirDB.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    CirDB.stop()
  end

  defp port, do: Application.get_env(:cir_db, :service)[:port] || 9666
  # defp ssl_port, do: Application.get_env(:cir_db, :ssl_port, 6443)
end
