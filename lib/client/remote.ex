defmodule CirDB.Client.Remote do

  def create_object(object) do
    url = CirDB.Config.get(:api_url)
    json = Jason.encode!(object)
    HttpReq.post("#{url}/create", [{"Content-Type", "application/json"}], json)
  end

  def update(id, vals), do: update(id, CirDB.now(), vals)
  def update(id, ts, vals) do
    url = CirDB.Config.get(:api_url)
    vals = vals |> Enum.map(&to_string/1) |> Enum.join(":")
    {:ok, response} = HttpReq.get("#{url}/update/#{id}/#{vals}/#{ts}")
    Jason.decode!(response[:body])
  end

  def fetch(id, config \\ %{scope: "32h"}) do
    url = CirDB.Config.get(:api_url)
    json = if is_struct(config) do
      config |> Map.from_struct() |> Jason.encode!()
    else
      Jason.encode!(config)
    end

    {:ok, response} = HttpReq.post("#{url}/fetch/#{id}", [{"Content-Type", "application/json"}], json)
    case Jason.decode!(response[:body], keys: :atoms) do
      %{data: data} ->
        %{
          result_ok: true,
          data: data
            |> Enum.map(&List.to_tuple/1)
        }

      _ -> %{result_ok: false}
    end
  end

end
