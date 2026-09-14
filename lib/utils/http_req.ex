defmodule HttpReq do
  @moduledoc false

  defp simple_request(method, url, headers, body) do
    content_type =
      case Enum.filter(headers, fn {k, _} -> k |> String.downcase() |> Kernel.==("content-type") end) do
        [{_, ct}|_] -> to_charlist(ct)
        _ -> ~c"text/plain"
      end
    headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    request = if method == :get, do: {url, headers}, else: {url, headers, content_type, to_charlist(body)}

    with {:ok, {status, headers, body}} <- :httpc.request(method, request, [], []) do
      headers = Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)

      {:ok,
       %{
         status: elem(status, 1),
         headers: headers,
         body: to_string(body)
       }}
    end
  end

  def get(url, headers \\ [], body \\ nil) do
    simple_request(:get, url, headers, body)
  end

  def post(url, headers \\ [], body \\ nil) do
    simple_request(:post, url, headers, body)
  end
end
