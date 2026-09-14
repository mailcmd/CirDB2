defmodule CirDB.Utils do
  def strtotime(str, time_offset \\ nil)
  def strtotime(int, _) when is_integer(int), do: int
  def strtotime(str, nil), do: strtotime(str, CirDB.Config.get(:time_offset))
  def strtotime(str, time_offset) do
    now = System.os_time(:second) + time_offset
    str
      |> String.replace(~r/now/, "#{now}", global: true)
      |> String.replace(~r/(seconds|second|secs|sec|s)/, "", global: true)
      |> String.replace(~r/([0-9]+)(?:months|month)/, "\\1*3600*24*28", global: true)
      |> String.replace(~r/([0-9]+)(?:minutes|minute|mins|min|m)/, "\\1*60", global: true)
      |> String.replace(~r/([0-9]+)(?:hours|hour|h)/, "\\1*3600", global: true)
      |> String.replace(~r/([0-9]+)(?:days|day|d)/, "\\1*3600*24", global: true)
      |> String.replace(~r/([0-9]+)(?:weeks|week|w)/, "\\1*3600*24*7", global: true)
      |> String.replace(~r/([0-9]+)(?:years|year|y)/, "\\1*3600*24*360", global: true)
      |> Code.eval_string()
      |> elem(0)
  end

  def tolerate_n_nils(datas, 0), do: datas
  def tolerate_n_nils([], _), do: []
  def tolerate_n_nils([{_, values} | datas] = all_datas, n) do
    if Enum.all?(values, &is_nil/1) do
      tolerate_n_nils(datas, n-1)
    else
      all_datas
    end
  end

end
