defmodule CirDB.Client.Local do
  def create_object(object), do: CirDB.create_object(object)
  def create_object(id, object), do: CirDB.create_object(id, object)

  def update(id, vals), do: CirDB.update(id, vals)
  def update(id, ts, vals), do: CirDB.update(id, ts, vals)

  def fetch(id, config \\ %CirDB.FetchConfig{}), do: CirDB.fetch(id, config)
end
