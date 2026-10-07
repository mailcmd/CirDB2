# CirDB

Circular DB is a timeseries DB at style of RRD but obtimized for high performance and
a minor resource consume. It has multithreading write and cached more used data for better
performance in read and write datas.

CirDB allow to enable a web service to get and put datas remotely inside the DB. 

# Initial idea

### Dirs struct

In disk:
```
    db
    |_ metadata.dets
    |_ daily.dets
    |_ weekly.dets
    |_ monthly.dets
    |_ yearly.dets
```

In ram (/dev/shm):
```
    db
    |_ daily.dets

```
Just the metadatas and daily data are in RAM disk. They are the most frequently accessed 
data. It is needed also a system to push to disk ram data every n seconds. 

### How it works?

1. The first time CirDB init create the files in disk and then copy daily file to RAM disk. 
2. The second and next times that CirDB init, look for daily disk file and daily cache file. 
   If cache file does not exists, copy disk to cache and open cache.
   If cache file exists, look last update of both files and copy the newest to disk or RAM 
   as needed. Then open the cache file.
2. When CirDB is running, you have open the daily cache file, the metadata disk file, and the 
   period consolidated disk files. 
3. Every N seconds CirDB copy the daily cache file to disk.
4. Every M seconds CirDB purge the objects that has not updates from one time to now. 

### Files structs

- metadata.dets format:
```
{
    obj_id, 
    daily_every, amount = div( 48*3600, daily_every ),
    6*daily_every, amount = div( 14*24*3600, 6*daily_every ),
    24*daily_every, amount = div( 56*24*3600, 24*daily_every ),
    144*daily_every, amount = div( 360*24*3600, 144*daily_every ),
    [{type_of_data, label, max, min}, {...}, {...}]
}
```

- daily.dets format:

```
{
    obj_id, 
    last_update_timestamp,
    array[{value_item_1, value_item_2, ...}, {...}]
}
```

- <period>.dets format:

```
{
    obj_id, 
    last_update_timestamp,
    array[{value_item_1, value_item_2, ...}, {...}], # AVG
    array[{value_item_1, value_item_2, ...}, {...}], # MAX
    array[{value_item_1, value_item_2, ...}, {...}]  # MIN
}
```


## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `cir_db` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:cir_db, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/cir_db>.

