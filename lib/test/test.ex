defmodule CirDB.Test do
  import CirDB
  alias CirDB.Item
  alias CirDB.Object

  def create() do
    items = [
      %Item{
        type: 0,
        label: "CPU",
        min: 0,
        max: 100
      },
      %Item{
        type: 2,
        label: "Traffic",
        min: 0,
        max: 2**34
      }
    ]
    create_object(%Object{id: "test", items: items})
  end

  def init() do
    create()
    id = "test"
    put(id)
    :timer.apply_interval(300_000, __MODULE__, :put, [id])
  end

  def put(id) do
    vals = [ Enum.random(1..100), 2*System.os_time(:second) ]
    ts = System.os_time(:second)
    IO.puts "#{inspect DateTime.from_unix!(ts)} (#{inspect ts}) - Upd: #{inspect vals} #{inspect update(id, vals)}"
  end
end
