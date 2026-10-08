defmodule CirDB do
  @moduledoc """
  Error list:
    -2  => Object not found
    -99 => Generic error, see message
  """

  @external_resource "ENV.sh"
  @external_resource "CIRDB_ENV.sh"

  # Determine if CirDB is installed as module or as server
  @is_module (File.cwd! |> Path.dirname() |> Path.basename()) == "deps"

  # ################################
  # ## ON COMPILE CHECK CONFIG FILE
  # ################################
  dest_dir = File.cwd! <> "/../../config/local/"
  if not File.exists?(dest_dir), do: File.mkdir_p(dest_dir)
  
  if @is_module and not File.exists?("#{dest_dir}/cir_db.exs") do
    IO.puts "[CirDB]: WARNING!!! We need to copy config.exs to config dir and rename it!!!!"
    IO.puts "[CirDB]: Coping config file to config/..."
    source_dir = File.cwd! <> "/config"
    File.cp!("#{source_dir}/config.exs", "#{dest_dir}/cir_db.exs")
    IO.puts "[CirDB]: Copy OK, RUN again!!!!"
    System.halt()
  end
  # ################################
  # ################################

  import CirDB.Utils

  defmodule Config do
    use Agent
    def init(), do: start_link([])

    def start_link(_config) do
      Agent.start_link(fn ->
        config = %{
          dir: System.get_env("CIRDB_DIR", "/var/cir_db"),
          cache_dir: System.get_env("CIRDB_CACHE_DIR", "/dev/shm/cir_db_cache"),
          id_length: System.get_env("CIRDB_ID_LENGTH", "10") |> Integer.parse() |> elem(0),

          # seconds
          time_offset: System.get_env("CIRDB_TIME_OFFSET", "-10800") |> Integer.parse() |> elem(0),
          sync_every: System.get_env("CIRDB_SYNC_EVERY", "300") |> Integer.parse() |> elem(0),
          purge_every: System.get_env("CIRDB_PURGE_EVERY", "86400") |> Integer.parse() |> elem(0),
          purge_older_than: System.get_env("CIRDB_PURGE_OLDER_THAN", "#{90*86400}") |> Integer.parse() |> elem(0),

          rrdtool_binary: System.get_env("CIRDB_RRDTOOL_BINARY_PATH", "/usr/bin/rrdtool"),
          api_url: System.get_env("CIRDB_API_URL", "http://localhost:9666/api/"),
        }

        config
          |> Map.put(:daily_cache_file, String.to_charlist(config[:cache_dir] <> "/daily.db"))
          |> Map.put(:metadata_file, String.to_charlist(config[:dir] <> "/metadata.db"))
          |> Map.put(:daily_file, String.to_charlist(config[:dir] <> "/daily.db"))
          |> Map.put(:weekly_file, String.to_charlist(config[:dir] <> "/weekly.db"))
          |> Map.put(:monthly_file, String.to_charlist(config[:dir] <> "/monthly.db"))
          |> Map.put(:yearly_file, String.to_charlist(config[:dir] <> "/yearly.db"))
      end, name: __MODULE__)
    end
    def get() do
      Agent.get(__MODULE__, fn config -> config end)
    end
    def get(key) do
      Agent.get(__MODULE__, fn config -> Map.get(config, key, nil) end)
    end
    def set(key, value) do
      Agent.update(__MODULE__, fn config -> Map.put(config, key, value) end)
    end
  end

  @types %{0 => :gauge, 1 => :counter32, 2 => :counter64}

  # @nils_tolerancy 2

  defmodule Object do
    defstruct [
      items: nil,
      daily_period: 300,      # 5 min
      # daily_amount: 576,    # 48 horas
      # weekly_period: 1800,  # 30 min
      # weekly_amount: 672,   # 14 dias
      # monthly_period: 7200, # 2 horas
      # monthly_amount: 672,  # 56 días
      # yearly_period: 43200, # 12 horas
      # yearly_amount: 720,   # 360 dias
      id: nil
    ]
  end

  defmodule Item do
    @enforce_keys [ :type, :label, :max, :min ]
    defstruct [
      :type,   # (0: GAUGE, 1: COUNTER32, 2: COUNTER64)
      :label,  # string max length 30
      :max,
      :min
    ]
  end

  defmodule FetchConfig do
    defstruct [
      :ts_start,
      :ts_end,
      scope: "32h",       # read as ts_start: :now and ts_end: (:now - 32h)
      aggregate: :avg,    # :avg | :max | :min
      time_as_string: false,
      first_row_labels: false,
      fix_missing_data: false
    ]
  end

  @type object() :: %Object{}
  @type item() :: %Item{}
  @type fetch_config() :: %FetchConfig{}


  @aggs %{
    avg: 0,
    max: 1,
    min: 2
  }

  ################################################################################################
  ## DB Management
  ################################################################################################

  @spec init() :: :ok
  def init() do
    ## Init Config getter
    CirDB.Config.init()

    ## Create struct and Init cache
    if not File.exists?(CirDB.Config.get(:daily_file)) do
      create_struct()
    else
      open_struct()
    end

    ## launch sync process
    :timer.apply_after(CirDB.Config.get(:sync_every)*1000, __MODULE__, :do_sync, [])

    ## launch purge process
    :timer.apply_after(CirDB.Config.get(:purge_every)*1000, __MODULE__, :do_purge, [])

    :ok
  end

  @spec stop() :: :ok
  def stop(), do: sync()

  @spec get_config() :: map()
  def get_config(), do: CirDB.Config.get()

  @spec do_sync() :: :ok
  def do_sync() do
    try do
      sync()
    catch
      _e -> :fail
    end
    :timer.apply_after(CirDB.Config.get(:sync_every)*1000, __MODULE__, :do_sync, [])
  end

  @spec do_purge() :: :ok
  def do_purge() do
    try do
      purge()
    catch
      _e -> :fail
    end
    :timer.apply_after(CirDB.Config.get(:purge_every)*1000, __MODULE__, :do_purge, [])
  end

  # Copy complete cache to db
  @spec sync() :: :ok
  def sync() do
    :dets.sync(:daily_cache)
    File.cp!(CirDB.Config.get(:daily_cache_file), CirDB.Config.get(:daily_file), on_conflict: &overwrite_older/2)
  end

  # Remove files older than CirDB.Config.get(:purge_older_than)
  @spec purge() :: :ok
  def purge() do
    older_than = CirDB.Config.get(:purge_older_than)
    filter = :ets.fun2ms(fn
        {_, ts, _} when ts < older_than -> true
    end)
    :dets.select_delete(:daily, filter)
    :dets.select_delete(:weekly, filter)
    :dets.select_delete(:monthly, filter)
    :dets.select_delete(:yearly, filter)
  end

  def initiated?() do
    CirDB.Config |> Process.whereis() |> is_pid()
  end
  ################################################################################################
  ## Object Management
  ################################################################################################

  # Create Object
  @spec create_object(object::object()) :: {:ok, id::String.t()} | {:error, reason::atom()}
  def create_object(%Object{id: id} = object) do
    id = to_string(id)
    daily_amount = div(48*3600, object.daily_period)
    weekly_amount = div(14*24*3600, 6*object.daily_period)
    monthly_amount = div(56*24*3600, 24*object.daily_period)
    yearly_amount = div(360*24*3600, 144*object.daily_period)
    
    items = create_object_h(object.items)
    
    row = {
      id,
      object.daily_period, daily_amount,
      6*object.daily_period, weekly_amount,
      24*object.daily_period, monthly_amount,
      144*object.daily_period, yearly_amount,
      items
    }
    :dets.insert_new(:metadata, row)
  end
  defp create_object_h([]), do: []
  defp create_object_h([ %Item{} = item | items ]) do
    [{item.type, item.label, item.max, item.min}] ++ create_object_h(items)
  end

  @spec update(id::any, vals::list()) :: :ok | {:error, reason::String.t()}
  def update(id, vals) when is_list(vals), do:
    update(id, now(), vals)
  def update({:error, _} = error, _, _), do: error
  def update(id, ts, vals) do
    id = to_string(id)
    object_info = object_info(id)
    timestamp = timestamp_align(ts, object_info[:daily].period)

    case object_info(id) do
      %{last_update: last_update} when last_update > timestamp ->
        {:error, "Timestamp equal or older than last_update"}

      %{items_count: items_count} when items_count == length(vals) ->
        index = get_position(ts, object_info, :daily)
        data = object_datas(:daily, id)
        data = :array.set(index, vals, data)
        :dets.insert(:daily_cache, {id, timestamp, data})

        # Hit the consolidation processes
        spawn(__MODULE__, :consolidate_object, [object_info, timestamp])
        :ok
      _ ->
        {:error, "Values count does not match with items count"}
    end
  end

  @spec object_info(id :: String.t()) :: {:error, String.t() | tuple()} | map()
  def object_info(id) do
    id = to_string(id)
    case :dets.lookup(:metadata, id) do
      [] ->
        {:error, {"Object does not exists", -2}}
        
      [{_,
        daily_period, daily_amount,
        weekly_period, weekly_amount,
        monthly_period, monthly_amount,
        yearly_period, yearly_amount,
        items
        
      }] ->
        %{
          id: id,
          items_count: length(items),
          items: items,
          last_update: object_last_update(id),
          daily: %{
            period: daily_period,
            amount: daily_amount
          },
          daily_cache: %{
            period: daily_period,
            amount: daily_amount
          },
          weekly: %{
            period: weekly_period,
            amount: weekly_amount
          },
          monthly: %{
            period: monthly_period,
            amount: monthly_amount
          },
          yearly: %{
            period: yearly_period,
            amount: yearly_amount
          }
        }
    end
  end

  @spec object_exists?(id :: String.t()) :: boolean()
  def object_exists?(id) do
    case object_info(id) do
      {:error, _} -> false
      _ -> true
    end
  end 
  
  # Consolidate datas if timestamp match any scope
  def consolidate_object(object_info, timestamp) do
    Enum.each([:weekly, :monthly, :yearly], fn scope ->
      if rem(timestamp, object_info[scope].period) == 0, do:
        spawn(__MODULE__, :consolidate_object_h, [object_info, scope])
    end)
  end

  def consolidate_object_h(object_info, scope) do
    last_datas = fetch(object_info.id, %FetchConfig{scope: "#{object_info[scope].period}secs"})
    {timestamp, _} = List.last(last_datas)
    avg_data = agg_avg(last_datas)
    max_data = agg_max(last_datas)
    min_data = agg_min(last_datas)
    index = get_position(timestamp, object_info, scope)
    {avg_datas, max_datas, min_datas} = object_datas(scope, object_info.id)
    avg_datas = :array.set(index, avg_data, avg_datas) 
    max_datas = :array.set(index, max_data, max_datas)
    min_datas = :array.set(index, min_data, min_datas)
    :dets.insert(scope, {object_info.id, timestamp, avg_datas, max_datas, min_datas})
  end

  # Last update timestamp
  @spec object_last_update(id::String.t()) :: timestamp::integer()
  def object_last_update(id) do
    id = to_string(id)
    case :dets.lookup(:daily_cache, id) do
      [] -> -1
      [{_, ts, _}] -> ts
    end
  end
  
  def object_datas(:daily, id), do: object_datas(:daily_cache, id)
  def object_datas(scope, id) do
    id = to_string(id)
    case {scope, :dets.lookup(scope, id)} do
      {:daily_cache, []} ->
        info = object_info(id)
        :array.new(info[scope].amount)
      {_, []} ->
        info = object_info(id)
        {
          :array.new(info[scope].amount), 
          :array.new(info[scope].amount), 
          :array.new(info[scope].amount)
        }
      {_, [{_, _, datas}]} ->
        datas
      {_, [{_, _, avg_datas, max_datas, min_datas}]} ->
        {avg_datas, max_datas, min_datas}
    end
  end

  @doc """
  Remember, this function return a list of tuples with the following format:
  {aligned_ts, {real_ts, [real_val1, real_val2, ..., real_valn]}}
  """
  @spec fetch_raw(id::any(), config::fetch_config()) :: list(tuple())
  def fetch_raw(id, %FetchConfig{} = config \\ %FetchConfig{}) do
    case object_info(id) do
      {:error, _} = error ->
        error

      %{items: _items} = object_info ->
        {ts_start, ts_end, scope} = parse_fetch_config(config)
        period = object_info[scope].period
        ts_start = timestamp_align(ts_start, period) - period
        ts_end = timestamp_align(ts_end, period)
        
        index_start = get_position(ts_start, object_info, scope)
        index_end = get_position(ts_end, object_info, scope)
        timestamps = ts_start..ts_end//period |> Enum.into([])

        data = 
          case object_datas(scope, id) do 
            {_, _, _} = datas -> 
              elem(datas, @aggs[config.aggregate])
            datas -> 
              datas
          end 
          
        data_list = 
          if index_start < index_end do
            :array.foldl(fn
              index, item, list when index >= index_start and index <= index_end ->
                [item | list]
              _, _, list ->
                list
            end, [], data)
            |> Enum.reverse()
          else
            {list_start, list_end} =
              :array.foldl(fn
                index, item, {list1, list2} when index >= index_start ->
                  {[item | list1], list2}
                index, item, {list1, list2} when index <= index_end ->
                  {list1, [item | list2]}
                _, _, list ->
                  list
              end, {[], []}, data)
            list_start = Enum.reverse(list_start)
            list_end = Enum.reverse(list_end)
            (list_start ++ list_end)
          end 
        
        result =
          timestamps
          |> Enum.zip(data_list)
          |> Enum.map(fn {ts, vals} ->
            nts = config.time_as_string && "#{DateTime.from_unix!(ts)}" || ts
            {nts, vals}
          end)

        if config.first_row_labels do
          [ {"timestamps_aligned", Enum.map(object_info.items, &(&1.label))} | result ]
        else
          result
        end
    end
  end

  @doc """
  Remember, this function return a list of tuples with the following format:
  {aligned_ts, [processed_val1, processed_val2, ..., processed_valn]}
  """
  @spec fetch(id::any(), config::fetch_config()) :: list(tuple())
  def fetch(id, %FetchConfig{} = config \\ %FetchConfig{}) do
    case fetch_raw(id, %{config | first_row_labels: false}) do
      {:error, _} = error ->
        error

      datas ->
        object_info = object_info(id)
        # items_types will be all :gauge if scope is not :daily
        parsed_config = parse_fetch_config(config)
        items_types =
          case parsed_config do
            {_, _, :daily} -> 
              Enum.map(object_info.items, fn {type, _, max, min} ->
                {@types[type], min, max}
              end)
            _ -> 
              Enum.map(object_info.items, fn {_, _, max, min} ->
                {:gauge, min, max}
              end)
          end

        result = 
          datas
          |> fetch_h(items_types)
          # fix only one nil problem
          |> fix_missing_data(config.fix_missing_data)
          |> Enum.reverse()
          
        now = now()
        {_, _, scope} = parsed_config
        period = object_info[scope].period
        
        result = 
          case result do
            [{ts, datas} | _] when now - ts <= period ->
              if Enum.all?(datas, &is_nil/1) do
                tl(result)
              else
                result
              end
            _ -> 
              result
          end
          |> Enum.reverse()
          
        if config.first_row_labels do
          [ {"timestamps", Enum.map(object_info.items, &(&1.label))} | result ]
        else
          result
        end
    end
  end

  defp has_nils(list), do: Enum.any?(list, &is_nil/1)

  defp middle_point([], _), do: []
  defp middle_point([v1 | list1], [v2 | list2]) do
    [v1+(v2-v1)/2 | middle_point(list1, list2)]
  end

  def fix_missing_data(datas, false), do: datas
  def fix_missing_data([d1, d2], _), do: [d1, d2]
  def fix_missing_data([{ts1, vs1} = d1, {ts2, vs2} = d2, {ts3,vs3} = d3 | datas], fix) do
    d2 =
      if not has_nils(vs1) and has_nils(vs2) and not has_nils(vs3) do
        {ts2, {div(ts3+ts1, 2), middle_point(vs1, vs3)}}
      else
        d2
      end
    [ d1 | fix_missing_data([d2, d3 | datas], fix) ]
  end

  def fetch_h([{ts1, :undefined} | datas], items_types), 
    do: fetch_h([{ts1, Enum.map(items_types, fn _ -> nil end)} | datas], items_types)
  def fetch_h([{ts1, vals1}, {ts2, :undefined} | datas], items_types), 
    do: fetch_h([{ts1, vals1}, {ts2, Enum.map(items_types, fn _ -> nil end)} | datas], items_types)
  def fetch_h([_], _), do: []
  def fetch_h([{ts1, vals1}, {ts2, vals2}], items_types), do:
    [ {ts2, fetch_process_vals_h(vals1, vals2, ts2 - ts1, items_types)} ]
  def fetch_h([{ts1, vals1}, {ts2, vals2} | datas], items_types) do
    processed_vals = fetch_process_vals_h(vals1, vals2, ts2 - ts1, items_types)
    [{ts2, processed_vals}]
    ++
    fetch_h([{ts2, vals2} | datas], items_types)
  end

  defp fetch_process_vals_h([], [], _, []), do: []
  # :gauge with v2 in range fall here
  defp fetch_process_vals_h([_v1 | vals1], [v2 | vals2], secs, [{:gauge, min, max} | items_types])
      when v2 >= min and v2 <= max do
    [v2] ++ fetch_process_vals_h(vals1, vals2, secs, items_types)
  end
  # :gauge with v2 out of range fall here
  defp fetch_process_vals_h([_v1 | vals1], [_v2 | vals2], secs, [{:gauge, _, _} | items_types]) do
    [nil] ++ fetch_process_vals_h(vals1, vals2, secs, items_types)
  end
  # :counterN with a nil value fall here
  defp fetch_process_vals_h([_v1 | vals1], [nil | vals2], secs, [_ | items_types]) do
    [nil] ++ fetch_process_vals_h(vals1, vals2, secs, items_types)
  end
  defp fetch_process_vals_h([nil | vals1], [_v2 | vals2], secs, [_ | items_types]) do
    [nil] ++ fetch_process_vals_h(vals1, vals2, secs, items_types)
  end
  # :counter32 overflowed
  defp fetch_process_vals_h([v1 | vals1], [v2 | vals2], secs, [{:counter32, min, max} | items_types])
      when v2 < v1 do
    value = (0xffffffff - v1 + v2)/secs
    [(if value < min or value > max, do: nil, else: value)] ++ fetch_process_vals_h(vals1, vals2, secs, items_types)
  end
  # :counter64 overflowed
  defp fetch_process_vals_h([v1 | vals1], [v2 | vals2], secs, [{:counter64, min, max} | items_types])
      when v2 < v1 do
    value = (0xffffffffffffffff - v1 + v2)/secs
    [(if (value < min or value > max), do: nil, else: value)] ++ fetch_process_vals_h(vals1, vals2, secs, items_types)
  end
  # :counter32 and :counter64 v2 > v1 fall here
  defp fetch_process_vals_h([v1 | vals1], [v2 | vals2], secs, [{_, min, max} | items_types]) do
    value = (v2 - v1)/secs
    [(if (value < min or value > max), do: nil, else: value)] ++ fetch_process_vals_h(vals1, vals2, secs, items_types)
  end
  ################################################################################################
  ## Not helpers private functions
  ################################################################################################


  def get_position(ts, object_info, scope), do:
    div(rem(ts, object_info[scope].amount * object_info[scope].period), object_info[scope].period)

  # align a timestamp to a period step
  def timestamp_align(ts, period) do
    div(ts, period) * period
  end

  # parse a fetch config and return ts_start, ts_end and scope
  @spec parse_fetch_config(config::fetch_config()) :: {
      ts_start::non_neg_integer(),
      ts_end::non_neg_integer(),
      :daily | :weekly | :monthly | :yearly
    } | :error
  def parse_fetch_config(config) do
    now = now()
    {ts_start, ts_end} =
      case config do
        %{scope: scope} when is_binary(scope) and byte_size(scope) > 0 ->
          time = strtotime(scope)
          cond do
            time < 0 ->
              {now + time, now}
            time <= 10*31104000 ->
              {now - time, now}
            true ->
              {time, now}
          end

        %{ts_start: ts_start, ts_end: ts_end} ->
          {strtotime(ts_start), strtotime(ts_end)}
      end

    cond do
      ts_start >= ts_end or ts_start > now ->
        :error
      ts_start < strtotime("#{now} - 2months") ->
        {ts_start, ts_end, :yearly}
      ts_start < strtotime("#{now} - 2weeks") ->
        {ts_start, ts_end, :monthly}
      ts_start < strtotime("#{now} - 2days") ->
        {ts_start, ts_end, :weekly}
      true ->
        {ts_start, ts_end, :daily}
    end
  end

  # really? do you need some explanation for this?
  def now() do
    System.os_time(:second) + CirDB.Config.get(:time_offset)
  end

  # Just if it is the first time it is opened
  defp create_struct() do
    File.mkdir_p!(CirDB.Config.get(:dir))
    File.mkdir_p!(CirDB.Config.get(:cache_dir))
    :dets.open_file(:daily, file: CirDB.Config.get(:daily_file))
    :dets.close(:daily)
    :dets.open_file(:metadata, file: CirDB.Config.get(:metadata_file))
    :dets.open_file(:weekly, file: CirDB.Config.get(:weekly_file))
    :dets.open_file(:monthly, file: CirDB.Config.get(:monthly_file))
    :dets.open_file(:yearly, file: CirDB.Config.get(:yearly_file))
    File.cp!(CirDB.Config.get(:daily_file), CirDB.Config.get(:daily_cache_file), on_conflict: &overwrite_older/2)
    :dets.open_file(:daily_cache, file: CirDB.Config.get(:daily_cache_file))
  end

  # If struct exists
  defp open_struct() do
    File.cp!(CirDB.Config.get(:daily_file), CirDB.Config.get(:daily_cache_file), on_conflict: &overwrite_older/2)
    :dets.open_file(:daily_cache, file: CirDB.Config.get(:daily_cache_file))
    :dets.open_file(:metadata, file: CirDB.Config.get(:metadata_file))
    :dets.open_file(:weekly, file: CirDB.Config.get(:weekly_file))
    :dets.open_file(:monthly, file: CirDB.Config.get(:monthly_file))
    :dets.open_file(:yearly, file: CirDB.Config.get(:yearly_file))
  end

  defp overwrite_older(source, destination) do
    {
      {:ok, %{mtime: s_mtime}},
      {:ok, %{mtime: d_mtime}}
    } = {
        File.stat(source),
        File.stat(destination)
    }
    s_mtime > d_mtime
  end

  def agg_avg(vals, accum \\ [])
  def agg_avg([], accum), do: Enum.map(accum, fn
    [] -> 0
    l -> :lists.sum(l)/length(l)
  end)
  def agg_avg([ {_, vals} | datas], []), do: agg_avg(datas, Enum.map(vals, &([&1])))
  def agg_avg([ {_, vals} | datas], accum) do
    agg_avg(datas, zip(vals, accum))
  end

  defp agg_max(vals, accum \\ [])
  defp agg_max([], accum), do: Enum.map(accum, fn
    [] -> 0
    l -> :lists.max(l)
  end)
  defp agg_max([ {_, vals} | datas], []), do: agg_max(datas, Enum.map(vals, &([&1])))
  defp agg_max([ {_, vals} | datas], accum) do
    agg_max(datas, zip(vals, accum))
  end

  defp agg_min(vals, accum \\ [])
  defp agg_min([], accum), do: Enum.map(accum, fn
    [] -> 0
    l -> :lists.min(l)
  end)
  defp agg_min([ {_, vals} | datas], []), do: agg_min(datas, Enum.map(vals, &([&1])))
  defp agg_min([ {_, vals} | datas], accum) do
    agg_min(datas, zip(vals, accum))
  end

  defp zip(list, list_of_list) do
    :lists.zipwith(fn
      (nil,[nil]) -> []
      (a,[nil]) -> [a]
      (nil,b) -> b
      (a,b) -> [a | b]
    end, list, list_of_list)
  end

end
