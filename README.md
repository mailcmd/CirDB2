# CirDB

CirDB (Circular Database) es un paquete que tiene una doble función, puede usarse como módulo en
otro proyecto Elixir o en modo standalone (service) como servidor de DB. 

## Como módulo
En este modo permite crear/actualizar/obterner objetos o datos de una DB. Se puede comunicar con 3 
tipos de DB: 
  - CirDB Local: la DB se encuentra en el mismo host donde está corriendo el módulo.
  - CirDB Remoto: la DB se encuentra en un host diferente al host donde está corriendo el módulo.
  - RRD Local: Esta es una interface que permite sólo obtener (no actualizar ni crear) datos desde
    un archivo RRD local.
  - RRD Remoto: (QUIZÁ EN EL FUTURO)

## Como servicio
En este modo, al iniciarse el servicio, si no existe la estructura será creada. Además lanzará 2 
tareas en el background para copiar desde el cache a la DB las novedades y para purgar archivos 
basura que vayan quedando durante su funcionamiento. 


# TODO
- [x] Consolidated process
- [x] Purge process (purge empty dirs and old files)
- [x] Sync to disk process
- [ ] Config set max scope
- [ ] Object set max scope
- [ ] Compress consolidated datas?


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
    |_ metadata.dets
    |_ daily.dets

```
Just the metadatas and daily data. They are the most frequently accessed data. It is needed also
a system to push to disk ram data every n seconds. 

### Files structs

- <period>.dets format:
```
{
    obj_id, 
    items_count, 
    daily_every,
    amount = div( 48*3600, daily_every ),
    amount = div( 14*24*3600, 6*daily_every ),
    amount = div( 56*24*3600, 24*daily_every ),
    amount = div( 360*24*3600, 144*daily_every ),
    [{type_of_data, label, max, min}, {...}, {...}],
    last_update_timestamp,
    array[{value_item_1, value_item_2, ...}, {...}]
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

