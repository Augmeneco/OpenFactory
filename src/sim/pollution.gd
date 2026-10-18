class_name Pollution
extends RefCounted
## The pollution map.
##
## Factorio keeps pollution per 32x32 chunk, not per tile: every machine adds
## its ``emissions_per_minute`` to the chunk it stands in, the chunks then
## trade pollution with their four neighbours and each chunk loses a little
## every second.  That is what makes a factory's smog spread outwards in a
## circle until it reaches a biter nest — and the nest then comes looking.
##
## The rates are the defaults from Factorio's map settings.

## Fraction of the difference between two chunks that moves each tick.
const DIFFUSION_RATIO := 0.02
## A chunk below this does not diffuse at all, which stops tiny amounts from
## smearing across the whole map.
const MIN_TO_DIFFUSE := 15.0
## Fraction of a chunk's pollution absorbed by its tiles each second.
##
## Factorio works this out from the absorption of every tile in the chunk,
## scaled by the map setting called ``ageing`` (documented as "the amount of
## pollution eaten by a chunk's tiles as a percentage of 1").  Neither number
## survives the prototype dump, so this is the equivalent rate: a lone stone
## furnace putting out 2 a minute settles at about 8 units, while a hundred of
## them settle in the high hundreds, which is the shape of a real Factorio
## cloud.
const DISSIPATION_PER_SECOND := 0.004
## Chunk edge, matching ``GameWorld.CHUNK_SIZE``.
const CHUNK_SIZE := 32

## A chunk is forgotten below this.  It has to be far below the smallest
## per-tick emission — a lone stone furnace adds 0.0006 a tick — or slow
## sources would be pruned before they could ever build up.
const PRUNE_BELOW := 1e-5

var world: GameWorld

## Chunk coordinate -> pollution.
var _chunks: Dictionary = {}
## Emissions banked during the current tick.
var _pending: Dictionary = {}
var _emitters := 0


func _init(world_: GameWorld) -> void:
	world = world_


static func chunk_of(cell: Vector2i) -> Vector2i:
	return Vector2i(int(floor(float(cell.x) / CHUNK_SIZE)),
		int(floor(float(cell.y) / CHUNK_SIZE)))


## Pollution of the chunk a cell falls in.
func pollution_at(cell: Vector2i) -> float:
	return float(_chunks.get(chunk_of(cell), 0.0))


func pollution_of_chunk(chunk: Vector2i) -> float:
	return float(_chunks.get(chunk, 0.0))


## How many chunks currently hold pollution, and the worst of them.
func stats() -> Dictionary:
	var worst := 0.0
	var total := 0.0
	for chunk: Vector2i in _chunks:
		var value := float(_chunks[chunk])
		worst = maxf(worst, value)
		total += value
	return {"chunks": _chunks.size(), "total": total, "worst": worst,
		"emitters": _emitters}


## Add pollution straight into a chunk.  Used by tests and by machines.
func add(cell: Vector2i, amount: float) -> void:
	if amount <= 0.0:
		return
	var chunk := chunk_of(cell)
	_pending[chunk] = float(_pending.get(chunk, 0.0)) + amount


func total() -> float:
	return float(stats()["total"])


# --------------------------------------------------------------------------
# tick
# --------------------------------------------------------------------------

## One tick: collect what the machines gave off, then spread and age it.
##
## ``emitters`` is a list of ``{ cell, rate }`` where rate is the prototype's
## ``emissions_per_minute`` for pollution.  A tick is a sixtieth of a second,
## so a rate per minute becomes ``rate / 60 / 60`` per tick.
func update(emitters: Array) -> void:
	_emitters = emitters.size()
	for entry: Dictionary in emitters:
		add(entry["cell"], float(entry["rate"]) / 3600.0)

	for chunk: Vector2i in _pending:
		_chunks[chunk] = float(_chunks.get(chunk, 0.0)) + float(_pending[chunk])
	_pending.clear()

	_diffuse()
	_age()


## Move pollution between neighbouring chunks, proportionally to the
## difference, so that everything eventually levels out.
func _diffuse() -> void:
	if _chunks.is_empty():
		return
	var deltas: Dictionary = {}
	for chunk: Vector2i in _chunks:
		var value := float(_chunks[chunk])
		if value <= MIN_TO_DIFFUSE:
			continue
		var move := 0.0
		for offset: Vector2i in [Vector2i(0, -1), Vector2i(1, 0),
				Vector2i(0, 1), Vector2i(-1, 0)]:
			var neighbour := chunk + offset
			var other := float(_chunks.get(neighbour, 0.0))
			if other >= value:
				continue
			var transfer := (value - other) * DIFFUSION_RATIO
			move += transfer
			deltas[neighbour] = float(deltas.get(neighbour, 0.0)) + transfer
		deltas[chunk] = float(deltas.get(chunk, 0.0)) - move

	for chunk: Vector2i in deltas:
		_chunks[chunk] = maxf(0.0, float(_chunks.get(chunk, 0.0)) + float(deltas[chunk]))
	_prune()


## Each chunk's tiles eat a share of what it holds, which is what stops a
## factory that has been shut down from leaving its smog behind for ever.
func _age() -> void:
	var kept := 1.0 - DISSIPATION_PER_SECOND / 60.0
	for chunk: Vector2i in _chunks:
		_chunks[chunk] = float(_chunks[chunk]) * kept
	_prune()


func _prune() -> void:
	var dead: Array = []
	for chunk: Vector2i in _chunks:
		if float(_chunks[chunk]) < PRUNE_BELOW:
			dead.append(chunk)
	for chunk: Vector2i in dead:
		_chunks.erase(chunk)


# --------------------------------------------------------------------------
# enemies
# --------------------------------------------------------------------------

## Chunks holding pollution that a nest could notice.
func polluted_chunks(minimum := 1.0) -> Array:
	var out: Array = []
	for chunk: Vector2i in _chunks:
		if float(_chunks[chunk]) >= minimum:
			out.append(chunk)
	return out


## Take pollution out of a chunk — what a spawner does when it feeds.
## Returns how much was actually removed.
func absorb(cell: Vector2i, amount: float) -> float:
	var chunk := chunk_of(cell)
	var stored := float(_chunks.get(chunk, 0.0))
	var taken: float = minf(amount, stored)
	if taken <= 0.0:
		return 0.0
	_chunks[chunk] = stored - taken
	_prune()
	return taken


## Whether a nest at ``cell`` is within ``radius`` of any real pollution.
##
## Factorio's biters do not react to a single unit of smog: the nest has to
## absorb pollution before it sends anything out, and this is the test for
## whether there is anything to absorb.
func nearest_pollution(from: Vector2i, radius_chunks: int) -> Vector2i:
	var origin := chunk_of(from)
	var best := Vector2i(-9999, -9999)
	var best_distance := 1e18
	for chunk: Vector2i in _chunks:
		var value := float(_chunks[chunk])
		if value <= 0.0:
			continue
		var distance := Vector2(chunk - origin).length()
		if distance > float(radius_chunks) or distance >= best_distance:
			continue
		best_distance = distance
		best = chunk
	return best


func clear() -> void:
	_chunks.clear()
	_pending.clear()


# --------------------------------------------------------------------------
# serialisation
# --------------------------------------------------------------------------

func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for chunk: Vector2i in _chunks:
		out["%d,%d" % [chunk.x, chunk.y]] = float(_chunks[chunk])
	return out


func from_dict(data: Dictionary) -> void:
	clear()
	for key: String in data:
		var parts := key.split(",")
		if parts.size() != 2:
			continue
		_chunks[Vector2i(int(parts[0]), int(parts[1]))] = float(data[key])
