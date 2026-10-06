if CirDB.MixProject.get_mode() == :service do
defmodule CirDB.Endpoint do
  use Plug.Router
  use Plug.ErrorHandler

  # require Logger

  alias Plug.Conn

  plug :match
  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["application/json"],
    json_decoder: {Jason, :decode!, [[keys: :atoms]]}
  plug :dispatch

  options "/api/*params" do
    conn |> send_response()
  end

  match "/favicon.ico" do
    conn |> Conn.send_resp(200, "data:;base64,=")
  end

  get "/api/*params" do
    conn
      |> CirDB.Service.process_call(params)
      |> send_response()
  end

  post "/api/*params" do
    conn
      |> check_json()
      |> CirDB.Service.process_call(params)
      |> send_response()
  end

  # Fallback match
  match _ do
    conn
      |> Conn.assign(:status, 401)
      |> Conn.assign(:message, "** nothing to see here **")
      |> send_response()
  end

  @impl Plug.ErrorHandler
  def handle_errors(%{method: "POST"} = conn, %{kind: _kind, reason: _reason, stack: _stack}) do
    send_resp(conn, conn.status, Jason.encode!(%{result_ok: false, error: "Malformed json request or bad params"}))
  end
  def handle_errors(%{method: "GET"} = conn, %{kind: _kind, reason: _reason, stack: _stack}) do
    send_resp(conn, conn.status, Jason.encode!(%{result_ok: false, error: "Bad params"}))
  end

  ##################################################################################################
  ## Private tools
  ##################################################################################################

  defp check_json(conn) do
    case conn.body_params do
      %{"_json" => json} ->
        conn
          |> Conn.assign(:json, json)
      %{} ->
        conn
          |> Conn.assign(:json, conn.body_params)
      _ ->
        conn
    end
  end

  # Run on dispatch
  defp send_response(conn) do
    message =
      cond do
        is_map(conn.assigns[:message]) -> Jason.encode!(conn.assigns[:message])
        is_list(conn.assigns[:message]) -> Jason.encode!(conn.assigns[:message])
        true -> conn.assigns[:message]
      end
    Conn.send_resp(conn, conn.assigns[:status] || 200, (message || ""))
  end
end
end
