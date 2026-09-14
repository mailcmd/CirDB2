defmodule CirDB do
  @moduledoc """
  Error list:
    -2  => Object not found
    -99 => Generic error, see message
  """

  @external_resource "ENV.sh"
  @external_resource "CIRDB_ENV.sh"

  @is_standalone (File.cwd! |> Path.dirname() |> Path.basename()) != "deps"

  # ################################
  # ## ON COMPILE CHECK CONFIG FILE
  # ################################
  dest_dir = File.cwd! <> "/../../config/local/"
  if not @is_standalone and not File.exists?("#{dest_dir}/cir_db.exs") do
    IO.puts "[CirDB]: WARNING!!! We need to copy config.exs.example to config dir and rename it!!!!"
    IO.puts "[CirDB]: Coping config file to config/..."
    source_dir = File.cwd! <> "/config"
    File.cp!("#{source_dir}/config.exs", "#{dest_dir}/cir_db.exs")
    File.cp!("#{source_dir}/../ENV.sh", "#{dest_dir}/../../CIRDB_ENV.sh")
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
          |> Map.put(:metadata_file, config[:dir] <> "/metadata.db")
          |> Map.put(:daily_file, config[:dir] <> "/daily.db")
          |> Map.put(:weekly_file, config[:dir] <> "/weekly.db")
          |> Map.put(:monthly_file, config[:dir] <> "/monthly.db")
          |> Map.put(:yearly_file, config[:dir] <> "/yearly.db")
          |> Map.put(:metadata_cache_file, config[:cache_dir] <> "/metadata.db")
          |> Map.put(:daily_cache_file, config[:cache_dir] <> "/daily.db")
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

  @nan_value <<1.0e-50::float>>
  @bin_header_size 8
  @bin_timestamp_size 4
  @bin_item_data_size 8

  @types %{0 => :gauge, 1 => :counter32, 2 => :counter64}

  @nils_tolerancy 2

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



  ################################################################################################
  ## DB Management
  ################################################################################################

  @spec init() :: :ok
  def init() do
    ## Init Config getter
    CirDB.Config.init()

    if @is_standalone do
      ## Create struct and Init cache
      if not File.exists?(CirDB.Config.get(:dir)) do
        create_struct()
      else
        open_struct() 
      end 

      ## launch sync process
      :timer.apply_after(CirDB.Config.get(:sync_every)*1000, __MODULE__, :do_sync, [])

      ## launch purge process
      :timer.apply_after(CirDB.Config.get(:purge_every)*1000, __MODULE__, :do_purge, [])
    end
    
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
    :dets.sync(:metadata_cache_file)
    File.cp_r!(CirDB.Config.get(:metadata_cache_file), CirDB.Config.get(:metadata_file), on_conflict: &overwrite_older/2)
    :dets.sync(:daily_cache_file)
    File.cp_r!(CirDB.Config.get(:daily_cache_file), CirDB.Config.get(:daily_file), on_conflict: &overwrite_older/2)
  end

  # Remove files older than CirDB.Config.get(:purge_older_than)
  @spec purge() :: :ok
  def purge() do
    now = now()
    filter = :ets.fun2ms(fn {_, ts, _} when ts < 45454 -> true end)
    :dets.select_delete(:da)
  end

  def initiated?() do
    CirDB.Config |> Process.whereis() |> is_pid()
  end
  ################################################################################################
  ## Object Management
  ################################################################################################

  # Create Object
  @spec create_object(object::object()) :: {:ok, id::String.t()} | {:error, reason::atom()}
  def create_object(object), do:
    create_object(object.id || random_id(), object)

  @spec create_object(id::any(), object::object()) :: {:ok, id::String.t()} | {:error, reason::atom()}
  def create_object(id, object) when is_integer(id), do: create_object(normalize_id(id), object)
  def create_object(id, %Object{items: items} = object) when is_binary(id) do
    id = byte_size(id) != CirDB.Config.get(:id_length) && normalize_id(id) || id
    filename = build_inf_filename(id)
    if File.exists?(filename) do
      {:error, "Object already exists!"}
    else
      daily_amount = div(48*3600, object.daily_period)
      weekly_amount = div(14*24*3600, 6*object.daily_period)
      monthly_amount = div(56*24*3600, 24*object.daily_period)
      yearly_amount = div(360*24*3600, 144*object.daily_period)

      bin =
        <<length(items)::8, 0, 0, 0>> <>
        <<object.daily_period::unsigned-size(32)>> <>
        <<daily_amount::unsigned-size(32)>> <>
        <<6*object.daily_period::unsigned-size(32)>> <>
        <<weekly_amount::unsigned-size(32)>> <>
        <<24*object.daily_period::unsigned-size(32)>> <>
        <<monthly_amount::unsigned-size(32)>> <>
        <<144*object.daily_period::unsigned-size(32)>> <>
        <<yearly_amount::unsigned-size(32)>> <>
        create_object_h(items)

      # create inf file
      {:ok, fd} = :file.open(filename, :write)
      :file.write(fd, bin)
      :file.close(fd)

      # create bin files
      init_bin_file(id, :daily, length(items), daily_amount)
      init_bin_file(id, :weekly, length(items), weekly_amount)
      init_bin_file(id, :monthly, length(items), monthly_amount)
      init_bin_file(id, :yearly, length(items), yearly_amount)

      copy_to_cache(id)

      {:ok, id}
    end
  end
  defp create_object_h([]), do: <<>>
  defp create_object_h([ %Item{} = item | items ]) do
    <<item.type::8, String.length(item.label)::8>> <> item.label <>
    <<item.max::float>> <>
    <<item.min::float>> <>
    create_object_h(items)
  end
  defp create_object_h([ item | items ]), do: create_object_h([ struct(Item, item )| items ])

  # Remove object
  @spec remove_object(id :: String.t()) :: :ok | {:error, reason::atom()}
  def remove_object(id) do
    with _ <- id |> build_inf_cache_filename() |> File.rm(),
         _ <- id |> build_bin_cache_filename() |> File.rm(),
         :ok <- id |> build_inf_filename() |> File.rm(),
         :ok <- id |> build_bin_filename(:daily) |> File.rm(),
         _ <- id |> build_bin_filename(:weekly) |> File.rm(),
         _ <- id |> build_bin_filename(:monthly) |> File.rm(),
         _ <- id |> build_bin_filename(:yearly) |> File.rm() do
      :ok
    else
      error -> error
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
    datas = fetch(object_info.id, %FetchConfig{scope: "#{object_info[scope].period}secs"})
    {timestamp, _} = List.last(datas)

    filename = build_bin_filename(object_info.id, scope)
    {:ok, fd} = :file.open(filename, [:read, :write, :binary, :raw])
    offset = pointer_offset(object_info, scope)

    # AVG
    bindata = datas
      |> agg_avg()
      |> vals_to_bin()
    {_, _, _, agg_pos} = scope_params(object_info, scope, :avg)
    pos = agg_pos + offset
    :file.pwrite(fd, pos, <<timestamp::unsigned-size(32)>> <> bindata)

    # MAX
    bindata = datas
      |> agg_max()
      |> vals_to_bin()
    {_, _, _, agg_pos} = scope_params(object_info, scope, :max)
    pos = agg_pos + offset
    :file.pwrite(fd, pos, <<timestamp::unsigned-size(32)>> <> bindata)

    # MIN
    bindata = datas
      |> agg_min()
      |> vals_to_bin()
    {_, _, _, agg_pos} = scope_params(object_info, scope, :min)
    pos = agg_pos + offset
    :file.pwrite(fd, pos, <<timestamp::unsigned-size(32)>> <> bindata)

    :file.pwrite(fd, 0, <<pointer_next(object_info, scope)::unsigned-size(32)>>)
    :file.close(fd)

  end

  # Object info
  @spec object_info(id :: String.t()) :: object_info::map() | {:error, msg::String.t() | tuple()}
  def object_info(id) do
    if not object_exists?(id) do
      {:error, {"Object does not exists", -2}}
    else
      inf_filename = build_inf_cache_filename(id)
      # if it is not in cache is copied to cache
      if not File.exists?(inf_filename), do: copy_to_cache(id)
      data = File.read!(inf_filename)

      <<
        _::32,
        daily_period::unsigned-size(32),
        daily_amount::unsigned-size(32),
        weekly_period::unsigned-size(32),
        weekly_amount::unsigned-size(32),
        monthly_period::unsigned-size(32),
        monthly_amount::unsigned-size(32),
        yearly_period::unsigned-size(32),
        yearly_amount::unsigned-size(32),
        data::binary
      >> = data

      items = object_info_h(data)
      items_count = length(items)
      {pointer, last_update} = object_header(id)

      %{
        id: id,
        last_update: last_update,
        pointer: pointer,
        cache_filename: build_bin_cache_filename(id),
        daily: %{
          filename: build_bin_filename(id, :daily),
          period: daily_period,
          amount: daily_amount,
          block_size: daily_amount * (@bin_timestamp_size + items_count * @bin_item_data_size),
        },
        weekly: %{
          filename: build_bin_filename(id, :weekly),
          period: weekly_period,
          amount: weekly_amount,
          block_size: weekly_amount * (@bin_timestamp_size + items_count * @bin_item_data_size),
        },
        monthly: %{
          filename: build_bin_filename(id, :monthly),
          period: monthly_period,
          amount: monthly_amount,
          block_size: monthly_amount * (@bin_timestamp_size + items_count * @bin_item_data_size),
        },
        yearly: %{
          filename: build_bin_filename(id, :yearly),
          period: yearly_period,
          amount: yearly_amount,
          block_size: yearly_amount * (@bin_timestamp_size + items_count * @bin_item_data_size),
        },
        items_count: items_count,
        items: items
      }
    end
  end
  defp object_info_h(data, items \\ [])
  defp object_info_h(<<>>, items), do: items
  defp object_info_h(data, items) do
    <<
      type::8,
      label_len::8, label::binary-size(label_len),
      max::float,
      min::float,
      data::binary
    >> = data
    object_info_h(data, items ++ [ %Item{
      type: type,
      label: label,
      max: max,
      min: min
    }])
  end

  # Last update timestamp
  @spec object_last_update(id::String.t()) :: timestamp::integer()
  def object_last_update(id), do: object_header(id, :daily) |> elem(1)

  @spec object_header(id::String.t(), scope::atom()) :: timestamp::integer()
  def object_header(id, scope \\ :daily)
  def object_header(id, scope) do
  try do    
    file = open_object(id, scope)
    {:ok, <<pointer::unsigned-size(32), items_count::unsigned-size(32)>>} = :file.read(file, @bin_header_size)
  
    size = :file.read_file_info(file) |> elem(1) |> elem(1)
    amount = div(size - 8, @bin_timestamp_size + @bin_item_data_size * items_count)
    pointer_prev =
      case pointer - 1 do
        ptr when ptr < 0 -> amount - 1
        ptr -> ptr
      end
    {:ok, <<ts::unsigned-size(32)>>} = :file.pread(file, @bin_header_size + pointer_prev * (@bin_timestamp_size + @bin_item_data_size * items_count), 4)
    close_object(file)
    {pointer, ts}
  rescue 
    e -> 
      IO.inspect {id, scope}
      reraise e, __STACKTRACE__
  end
  end

  # Object exists?
  @spec object_exists?(id::any()) :: exists::boolean()
  def object_exists?(id) do
    filename = 
      id 
      |> normalize_id() 
      |> build_bin_filename(:daily) 
      
    real_file = 
      case File.stat(filename) do
        {:error, _} -> false
        {:ok, %File.Stat{size: size}} when size == 0 -> false
        _ -> true
      end    
    
    cache_filename = 
      id 
      |> normalize_id() 
      |> build_bin_cache_filename()
      
    cache_file = 
      case File.stat(cache_filename) do
        {:error, _} -> false
        {:ok, %File.Stat{size: size}} when size == 0 -> false
        _ -> true
      end        

    real_file and cache_file
  end

  ################################################################################################
  ## Items Management
  ################################################################################################

  # Update items
  @spec update(id::any, vals::list()) :: :ok | {:error, reason::String.t()}
  def update(id, vals) when is_list(vals), do:
    update(id, now(), vals)
  def update(id, ts, vals) when is_integer(id) or is_binary(id), do:
    id |> normalize_id() |> object_info() |> update(ts, vals)
  # def update(id, ts, vals) when is_binary(id) do
  #   id |> normalize_id() |> object_info() |> update(ts, vals)
  # end
  def update({:error, _} = error, _, _), do: error
  def update(object_info, ts, vals) do
    timestamp = timestamp_align(ts, object_info.daily.period)

    case object_info do
      {:error, _} = error ->
        error

      %{last_update: last_update} when last_update > timestamp ->
        {:error, "Timestamp equal or older than last_update"}

      %{items_count: items_count} = object when items_count == length(vals) ->
        # get position in file
        pos = @bin_header_size +
          if timestamp == object.last_update do
            pointer_prev_offset(object, :daily)
          else
            pointer_offset(object, :daily)
          end

        bindata = vals_to_bin(vals)

        {:ok, fd} = :file.open(object.cache_filename, [:read, :write, :binary, :raw])

        # write data to position
        :file.pwrite(fd, pos, <<ts::unsigned-size(32)>> <> bindata)
        if timestamp > object.last_update, do:
          :file.pwrite(fd, 0, <<pointer_next(object, :daily)::unsigned-size(32)>>)
        :file.close(fd)

        spawn(__MODULE__, :consolidate_object, [object_info, timestamp])
        # consolidate_object(object_info, timestamp)
        :ok
      _ ->
        {:error, "Values count does not match with items count"}
    end
  end

  @doc """
  Remember, this function return a list of tuples with the following format:
  {aligned_ts, {real_ts, [real_val1, real_val2, ..., real_valn]}}
  """
  @spec fetch_raw(id::any(), config::fetch_config()) :: list(tuple())
  def fetch_raw(id, %FetchConfig{} = config \\ %FetchConfig{}) do
    id = normalize_id(id)
    case object_info(id) do
      {:error, _} = error ->
        error

      %{items: _items} = object ->
        {ts_start, ts_end, scope} = parse_fetch_config(config)
        {period, _amount, _block_size, block_position} = scope_params(object, scope, config.aggregate)

        pointer = pointer(object, scope)
        pointer_position = block_position + pointer_next_offset(object, scope)
        data_unit_size = data_unit_size(object)

        file = open_object(id, scope)

        bindata =
          (:file.pread(
            file,
            pointer_position,
            (object[scope].amount - (pointer + 1)) * data_unit_size
          ) |> elem(1)) <> (:file.pread(
            file,
            block_position, pointer * data_unit_size) |> elem(1))

        :file.close(file)

        ts_start = timestamp_align(ts_start, period) - period
        ts_end = timestamp_align(ts_end, period)
        timestamps = ts_start..ts_end//period |> Enum.into([])

        datas = bindata
          |> :binary.bin_to_list()
          |> Stream.chunk_every(data_unit_size)
          |> Stream.map(fn list ->
            [ts | vals] = list |> :binary.list_to_bin() |> extract_items_data()
            tsa = timestamp_align(ts, period)
            {tsa, {ts, vals}}
          end)
          |> Stream.filter(fn {tsa, _} ->
            tsa >= ts_start and tsa <= ts_end
          end)
          |> Enum.into(%{})

        result = timestamps
          |> Enum.map(fn ts ->
            nts = config.time_as_string && "#{DateTime.from_unix!(ts)}" || ts
            datas[ts] == nil
              && {nts, {ts, (for _ <- 1..object.items_count, do: nil)}}
              || {nts, datas[ts]}
          end)

        if config.first_row_labels do
          [ {"timestamps_aligned", {"timestamps", Enum.map(object.items, &(&1.label))}} | result ]
        else
          result
        end

      _ ->
        {:error, "Bad or missing %FechConfig{}"}
    end
  end

  @doc """
  Remember, this function return a list of tuples with the following format:
  {aligned_ts, [processed_val1, processed_val2, ..., processed_valn]}
  """
  @spec fetch(id::any(), config::fetch_config()) :: list(tuple())
  def fetch(id, %FetchConfig{} = config \\ %FetchConfig{}) do
    id = normalize_id(id)
    case fetch_raw(id, %{config | first_row_labels: false}) do
      {:error, _} = error ->
        error

      datas ->
        object = object_info(id)
        # items_types will be all :gauge if scope is not :daily
        items_types =
          case parse_fetch_config(config) do
            {_, _, :daily} -> Enum.map(object.items, &({@types[&1.type], &1.min, &1.max}))
            _ -> Enum.map(object.items, &({:gauge, &1.min, &1.max}))
          end

        result = datas
          # fix only one nil problem
          |> fix_missing_data(config.fix_missing_data)
          # process data
          |> fetch_h(items_types)
          # purge last n rows if all values are nil's
          |> Enum.reverse()
          |> CirDB.Utils.tolerate_n_nils(@nils_tolerancy)
          |> Enum.reverse()


        if config.first_row_labels do
          [ {"timestamps", Enum.map(object.items, &(&1.label))} | result ]
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
  def fix_missing_data([{_, {ts1,vs1}} = d1, {tas2, {_,vs2}} = d2, {_, {ts3,vs3}} = d3 | datas], fix) do
    d2 =
      if not has_nils(vs1) and has_nils(vs2) and not has_nils(vs3) do
        {tas2, {div(ts3+ts1, 2), middle_point(vs1, vs3)}}
      else
        d2
      end
    [ d1 | fix_missing_data([d2, d3 | datas], fix) ]
  end

  defp fetch_h([{_, {ts1, vals1}}, {tsa2, {ts2, vals2}}], items_types), do:
    [ {tsa2, fetch_process_vals_h(vals1, vals2, ts2 - ts1, items_types)} ]
  defp fetch_h([{_, {ts1, vals1}}, {tsa2, {ts2, vals2}} | datas], items_types) do
    processed_vals = fetch_process_vals_h(vals1, vals2, ts2 - ts1, items_types)
    [ {tsa2, processed_vals} ]
    ++
    fetch_h([{tsa2, {ts2, vals2}} | datas], items_types)
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

  # extract timestamp and values from bindatas and return a list
  defp extract_items_data(bindata) do
    <<timestamp::unsigned-size(32), bindata::binary>> = bindata
    [ timestamp | extract_items_data_h(bindata)]
  end
  def extract_items_data_h(<<>>), do: []
  def extract_items_data_h(bindata) do
    <<f::float, bindata::binary>> = bindata
    [ (if <<f::float>> == @nan_value, do: nil, else: f) ] ++ extract_items_data_h(bindata)
  end

  # calculate the size of a data unit (ts + values)
  defp data_unit_size(object) do
    @bin_timestamp_size + @bin_item_data_size * object.items_count
  end

  # analize object and scope and return some useful datas:
  #    {period, amount, block_size, block_position}
  #       ^       ^          ^            ^
  #       |       |          |            |
  #     period   amount   size in      absolute position in
  #   of scope  of datas  bytes of     file of the first data of
  #            that this  amount need   the block
  #          scope store
  def scope_params(object, scope, agg) do
    {period, amount, block_size} =
      {object[scope].period, object[scope].amount, object[scope].block_size}
    block_position = @bin_header_size + block_size * (scope == :daily && 0 || agg_offset(agg))
    {period, amount, block_size, block_position}
  end

  # get the pointer value for scope
  def pointer(object, scope) do
    object_header(object.id, scope) |> elem(0)
  end

  # get the next pointer value for scope
  def pointer_next(object, scope) do
    amount = object[scope].amount
    case pointer(object, scope) + 1 do
      pointer when pointer >= amount ->
        pointer - amount
      pointer ->
        pointer
    end
  end

  # get the prev pointer value for scope
  def pointer_prev(object, scope) do
    case pointer(object, scope) - 1 do
      pointer when pointer < 0 ->
        object[scope].amount + pointer
      pointer ->
        pointer
    end
  end

  # calculate the offset inside a block of datas for the current value of the pointer
  defp pointer_offset(object, scope) do
    pointer(object, scope) * data_unit_size(object)
  end

  # calculate the offset inside a block of datas for the next value of the pointer
  defp pointer_next_offset(object, scope) do
    pointer_next(object, scope) * data_unit_size(object)
  end

  # calculate the offset inside a block of datas for the prev value of the pointer
  defp pointer_prev_offset(object, scope) do
    pointer_prev(object, scope) * data_unit_size(object)
  end

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

  # really? do you need some explaination for this?
  def now() do
    System.os_time(:second) + CirDB.Config.get(:time_offset)
  end

  #
  defp init_bin_file(id, scope, items_count, amount) do
    {:ok, fd} = id |> build_bin_filename(scope) |> :file.open(:write)
    empty_data = <<0::32>> <> String.duplicate(@nan_value, items_count)
    nan_datas =
        # header (ptr + items_count)
        <<0::32>> <> <<items_count::unsigned-size(32)>> <>
        # <amount> nan's
        String.duplicate(empty_data, amount * ((scope != :daily) && 3 || 1))
    :file.write(fd, nan_datas)
    :file.close(fd)
  end

  # Just if it is the first time it is opened
  defp create_struct() do
    File.mkdir_p!(CirDB.Config.get(:cache_dir))
    :dets.open_file(:metadata_cache, CirDB.Config.get(:metadata_cache_file))
    :dets.open_file(:daily_cache, CirDB.Config.get(:daily_cache_file))
    File.mkdir_p!(CirDB.Config.get(:dir))
    :dets.open_file(:weekly, file: CirDB.Config.get(:weekly_file))
    :dets.open_file(:monthly, file: CirDB.Config.get(:monthly_file))
    :dets.open_file(:yearly, file: CirDB.Config.get(:yearly_file))
  end

  # If struct exists    
  defp open_struct() do
    File.cp_r!(CirDB.Config.get(:metadata_file), CirDB.Config.get(:metadata_cache_file), on_conflict: &overwrite_older/2)
    File.cp_r!(CirDB.Config.get(:daily_file), CirDB.Config.get(:daily_cache_file), on_conflict: &overwrite_older/2)
    :dets.open_file(:metadata_cache, CirDB.Config.get(:metadata_cache_file))
    :dets.open_file(:daily_cache, CirDB.Config.get(:daily_cache_file))
    :dets.open_file(:weekly, file: CirDB.Config.get(:weekly_file))
    :dets.open_file(:monthly, file: CirDB.Config.get(:monthly_file))
    :dets.open_file(:yearly, file: CirDB.Config.get(:yearly_file))
  end

  # Copy complete db to cache
  defp copy_to_cache(id) do
    metadata_filename = build_inf_filename(id)
    metadata_cache_filename = build_inf_cache_filename(id)
    File.cp(metadata_filename, metadata_cache_filename, on_conflict: &overwrite_older/2)

    daily_filename = build_bin_filename(id, :daily)
    daily_cache_filename = build_bin_cache_filename(id)
    File.cp(daily_filename, daily_cache_filename, on_conflict: &overwrite_older/2)
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

  def normalize_id(id) when is_integer(id), do: to_string(id)
  def normalize_id(id), do: id

  defp agg_offset(:avg), do: 0
  defp agg_offset(:max), do: 1
  defp agg_offset(:min), do: 2

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

  defp vals_to_bin(vals) do
    Enum.reduce(vals, <<>>, fn
      nil,a -> a ++ [@nan_value]
      v,a -> a ++ [v]
    end)
  end

end
