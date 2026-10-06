defmodule CirDB.Service do
  @doc """
  API Calls availables:
    - GET update/id/values (values are separed with ":")
    - POST batch_update (json param)
      [
        [id, values],
        [id, values],
        ...
      ]
    - POST create (json param)
      {
        "id": "<id>",
        "daily_period": 300,
        "items": [
          {
            "type": <int>,        #(0: GAUGE, 1: COUNTER32, 2: COUNTER64)
            "label": "<string>",
            "max": <numeric>,
            "min": <numeric>
          },
          {
            ...
          }
        ]
      }

  Error list:
    -2  => Object not found
    -3  => Bad create parameters!
    -99 => Generic error, see message

  """


  alias Plug.Conn

  def process_call(conn, []) do
    conn
      |> Conn.assign(:message, %{result_ok: false, error: "Non-existent API call!", errno: -1})

  end
  def process_call(conn, [api_call | params]) do
    case {conn.method, api_call} do
      {"GET", "update"} ->
        update(conn, params)

      {"POST", "batch_update"} ->
        conn
          |> Conn.assign(:message, [])
          |> update(conn.assigns[:json])

      {"POST", "create"} ->
        create(conn, conn.assigns[:json], params)

      {"POST", "fetch"} ->
        fetch(conn, conn.assigns[:json], params)

      _ ->
        process_call(conn, [])
    end
  end

  ##################################################################################################
  ## Private tools
  ##################################################################################################

  # if it is batch_update
  defp update(conn, []), do: conn
  defp update(conn, [list | rest]) when is_list(list) do
    conn
      |> update(list)
      |> update(rest)
  end
  # if it is update
  defp update(conn, [id, values]), do: update(conn, [id, values, CirDB.now()])
  defp update(conn, [id, values, ts]) when is_binary(ts),
    do: update(conn, [id, values, ts |> Integer.parse() |> elem(0)])
  defp update(conn, [id, values, ts]) do
    values = values |> String.split(":") |> Enum.map(fn v -> v |> Float.parse() |> elem(0) end)
    case CirDB.update(id, ts, values) do
      :ok ->
        conn
          |> Conn.assign(:message, update_message(conn.assigns[:message], %{result_ok: true}))
          |> Conn.assign(:status, 200)

      {:error, {reason, errno}} ->
        conn
          |> Conn.assign(:message, update_message(conn.assigns[:message], %{result_ok: false, error: reason, errno: errno}))
          |> Conn.assign(:status, 401)

      {:error, reason} ->
        conn
          |> Conn.assign(:message, update_message(conn.assigns[:message], %{result_ok: false, error: reason, errno: -99}))
          |> Conn.assign(:status, 401)
    end
  end

  defp update_message(messages, new_message) when is_list(messages), do: messages ++ [new_message]
  defp update_message(_, new_message), do: new_message

  # Create object
  defp create(conn, json, _params) do
    with %{daily_period: _, items: _} = object <- json,
        object <- struct(CirDB.Object, object),
        {:ok, id} <- CirDB.create_object(object) do
      conn
        |> Conn.assign(:message, %{result_ok: true, object_id: id})
        |> Conn.assign(:status, 200)

    else
      {:error, reason} ->
        conn
          |> Conn.assign(:message, %{result_ok: false, error: reason, errno: -99})
          |> Conn.assign(:status, 401)

      _ ->
        conn
          |> Conn.assign(:message, %{result_ok: false, error: "Bad create parameters!", errno: -3})
          |> Conn.assign(:status, 401)
    end
  end

  defp fetch(conn, json, [id]) do
    json = update_in(json, [:aggregate], fn
      agg when is_binary(agg) -> String.to_atom(agg)
      agg -> agg
    end)
    data = CirDB.fetch(id, struct(CirDB.FetchConfig, json))
      |> Enum.map(&Tuple.to_list/1)
    conn
      |> Conn.assign(:message, %{result_ok: true, data: data})
      |> Conn.assign(:status, 200)
  end

end
