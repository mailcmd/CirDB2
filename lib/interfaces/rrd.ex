defmodule CirDB.RRD do
  @nils_tolerancy 3

  # RRDFETCH Output
  #                 Entrante            Saliente
  #
  # 1757338200: 1.9185456370e+08 1.3545798266e+08
  # 1757340000: 2.2259752383e+08 1.5535056879e+08
  # 1757341800: 2.3883737833e+08 1.6583369022e+08
  # ...
  # ...
  # 1757505600: 1.3741934438e+08 1.0457212933e+08
  # 1757507400: 1.5902404730e+08 1.1134407322e+08
  # 1757509200: 1.8035088486e+08 1.3061526623e+08
  # 1757511000: -nan -nan

  def fetch(filename, %{} = fetch_config, function, ds_list \\ []) do
    {ts_start, ts_end, scope} = CirDB.parse_fetch_config(fetch_config)

    case System.shell("#{CirDB.Config.get(:rrdtool_binary)} fetch #{filename} #{String.upcase(function)} -s #{ts_start - CirDB.Config.get(:time_offset)} -e #{ts_end - CirDB.Config.get(:time_offset)} -r #{scope2period(scope)} 2>&1") do
      {output, 0} ->
        lines = String.split(output, ~r/\n/)
        [header, _spacer | lines] = lines
        datas = lines
          |> Stream.filter(fn line -> String.trim(line) != "" end)
          |> Stream.map(fn line ->
            [ts | vals] = line |> String.replace(":", "") |> String.split(" ")
            {
              String.to_integer(ts) + CirDB.Config.get(:time_offset),
              Enum.map(vals, fn
                "-nan" -> nil
                v -> String.to_float(v)
              end)
            }
          end)
          |> Enum.into([])
          # purge last n rows if all values are nil's
          |> Enum.reverse()
          |> CirDB.Utils.tolerate_n_nils(@nils_tolerancy)
          |> Enum.reverse()

        rrd_ds = header |> String.trim() |> String.split(~r/[\s]+/)
        {labels, datas} =
          case ds_list do
            [] -> {rrd_ds, datas}
            ds_list ->
              indexes = Enum.map(ds_list, fn ds -> Enum.find_index(rrd_ds, &(&1==ds)) end)
              {
                Enum.filter(rrd_ds, fn d -> Enum.member?(ds_list, d) end),
                datas
                  |> Enum.map(fn {x, ys} ->
                    {x, Enum.map(indexes, &Enum.at(ys, &1))}
                  end)
              }
          end

        if fetch_config.first_row_labels do
          [{"timestamps", labels } | datas]
        else
          datas
        end

      {error, _} ->
        {:error, error}
    end
  end


  ################################################################################################
  ## Not helpers private functions
  ################################################################################################

  defp scope2period(:daily), do: 300
  defp scope2period(:weekly), do: 6*300
  defp scope2period(:monthly), do: 24*300
  defp scope2period(:yearly), do: 144*300

end
