class_name GameWorld
extends RefCounted
## Chunked tile world plus the entities standing on it.
##
## Terrain is produced procedurally per 32x32 chunk and cached, so the map is
## effectively unbounded like Factorio's.  Ore is stored per cell (it is
## terrain-like: one ore entity per tile) while machines live in a sparse
## dictionary keyed by their origin tile.

const CHUNK := 32
const CHUNK_AREA := CHUNK * CHUNK

## Tile names that map generation is allowed to emit, indexed by byte id.
var palette: PackedStringArray = PackedStringArray()
var _palette_index: Dictionary = {}

var seed: int = 0
var generator: MapGenerator

var _chunks: Dictionary = {}
## Chunks the engineer has actually explored or a powered radar has scanned.
## Generated chunks can exist for saving/simulation without being visible on
## the satellite map; the map deliberately shows noise until this set has them.
var revealed_chunks: Dictionary = {}          ## Vector2i -> Chunk
var entities: Dictionary = {}         ## Vector2i -> Entity
var _entity_owner: Dictionary = {}    ## Vector2i -> Entity (every covered cell)
var _type_index: Dictionary = {}      ## prototype type -> Array[Entity]
var _index_dirty := true
## Bumped whenever anything the renderer can see changes — a tile, a unit of
## ore, an entity.  The renderer keeps its prepared ground rectangles keyed by
## this, so it can reuse them instead of rebuilding thousands of cells a frame.
var revision := 0
## Per-cell change stamps, so a map view can cache one cell's colour and only
## recompute the cells that actually changed (mining one ore tile, setting one
## tile) instead of throwing away the whole picture.
var _cell_stamps: Dictionary = {}
var _next_cell_stamp := 0
## Per-chunk change stamps.  The minimap and the map draw cached 32x32 chunk
## pictures; a stamp that changes only when that chunk's ground or ore changes
## keeps them from rebuilding the whole map.
var _chunk_stamps: Dictionary = {}
var _next_chunk_stamp := 0
## Incremented when the whole map is replaced (new game, load), so caches that
## remember one cell's colour can throw everything away even though the
## per-cell stamps of the fresh world start at zero again.
var epoch := 0

signal chunk_generated(coord: Vector2i)
signal entity_placed(entity: Entity)
signal entity_removed(entity: Entity)


class Chunk:
	extends RefCounted
	var tiles: PackedByteArray
	var ore: PackedByteArray          ## 0 = none, otherwise ore palette id + 1
	var amount: PackedFloat32Array
	var generated := false

	func _init() -> void:
		tiles = PackedByteArray()
		tiles.resize(CHUNK_AREA)
		ore = PackedByteArray()
		ore.resize(CHUNK_AREA)
		amount = PackedFloat32Array()
		amount.resize(CHUNK_AREA)


func _init(world_seed: int = 0) -> void:
	seed = world_seed
	generator = MapGenerator.new(world_seed)


# --------------------------------------------------------------------------
# tile palette
# --------------------------------------------------------------------------

func register_tile(tile_name: String) -> int:
	if _palette_index.has(tile_name):
		return _palette_index[tile_name]
	var id := palette.size()
	palette.append(tile_name)
	_palette_index[tile_name] = id
	return id


## Id of a tile in the palette, registering it on first use so the procedural
## generator never has to know the palette up front.
func tile_id(tile_name: String) -> int:
	if not _palette_index.has(tile_name):
		return register_tile(tile_name)
	return _palette_index[tile_name]


## A number that changes whenever ``cell``'s terrain or ore does.
func cell_stamp(cell: Vector2i) -> int:
	return int(_cell_stamps.get(cell, 0))


func _bump_cell(cell: Vector2i) -> void:
	_next_cell_stamp += 1
	_cell_stamps[cell] = _next_cell_stamp
	_next_chunk_stamp += 1
	_chunk_stamps[chunk_of(cell)] = _next_chunk_stamp


## A number that changes when a chunk's tile or ore data does.
func chunk_stamp(coord: Vector2i) -> int:
	return int(_chunk_stamps.get(coord, 0))


func _bump_chunk(coord: Vector2i) -> void:
	_next_chunk_stamp += 1
	_chunk_stamps[coord] = _next_chunk_stamp


func tile_name(id: int) -> String:
	if id < 0 or id >= palette.size():
		return palette[0] if palette.size() > 0 else ""
	return palette[id]


# --------------------------------------------------------------------------
# chunk access
# --------------------------------------------------------------------------

static func chunk_of(cell: Vector2i) -> Vector2i:
	return Vector2i(
		int(floor(float(cell.x) / CHUNK)),
		int(floor(float(cell.y) / CHUNK)))


static func local_of(cell: Vector2i) -> int:
	var lx := posmod(cell.x, CHUNK)
	var ly := posmod(cell.y, CHUNK)
	return ly * CHUNK + lx


func chunk(coord: Vector2i) -> Chunk:
	var existing: Variant = _chunks.get(coord)
	if existing != null:
		return existing
	var made := Chunk.new()
	_chunks[coord] = made
	generator.fill_chunk(self, coord, made)
	made.generated = true
	revision += 1
	_bump_chunk(coord)
	chunk_generated.emit(coord)
	return made


func is_generated(coord: Vector2i) -> bool:
	return _chunks.has(coord)


func reveal_chunk(coord: Vector2i) -> void:
	revealed_chunks[coord] = true


func is_chunk_revealed(coord: Vector2i) -> bool:
	return revealed_chunks.has(coord)


func tile_at(cell: Vector2i) -> String:
	var c := chunk(chunk_of(cell))
	return tile_name(c.tiles[local_of(cell)])


func tile_id_at(cell: Vector2i) -> int:
	var c := chunk(chunk_of(cell))
	return c.tiles[local_of(cell)]


func set_tile(cell: Vector2i, tile_name_: String) -> void:
	var coord := chunk_of(cell)
	var c := chunk(coord)
	c.tiles[local_of(cell)] = register_tile(tile_name_)
	revision += 1
	_bump_cell(cell)


## ``{ name = "", amount = 0.0 }`` when the cell carries no ore.
func ore_at(cell: Vector2i) -> Dictionary:
	var c := chunk(chunk_of(cell))
	var idx := local_of(cell)
	var ore_id := c.ore[idx]
	if ore_id == 0:
		return {"name": "", "amount": 0.0}
	return {"name": generator.ore_name(ore_id), "amount": c.amount[idx]}


func set_ore(cell: Vector2i, ore_name: String, amount: float) -> void:
	var c := chunk(chunk_of(cell))
	var idx := local_of(cell)
	if ore_name.is_empty() or amount <= 0.0:
		c.ore[idx] = 0
		c.amount[idx] = 0.0
		revision += 1
		_bump_cell(cell)
		return
	c.ore[idx] = generator.ore_id(ore_name)
	c.amount[idx] = amount
	revision += 1
	_bump_cell(cell)


func mine_ore(cell: Vector2i, amount: float) -> float:
	var c := chunk(chunk_of(cell))
	var idx := local_of(cell)
	if c.ore[idx] == 0:
		return 0.0
	var taken: float = minf(c.amount[idx], amount)
	c.amount[idx] -= taken
	if c.amount[idx] <= 0.0:
		c.ore[idx] = 0
		c.amount[idx] = 0.0
	revision += 1
	_bump_cell(cell)
	return taken


# --------------------------------------------------------------------------
# entities
# --------------------------------------------------------------------------

func can_place(entity: Entity) -> bool:
	for cell in entity.occupied_cells():
		if _entity_owner.has(cell):
			return false
	return true


## Whether the ground under an entity allows it to be built.
##
## Factorio's rules that matter here: nothing goes on water (landfill is a
## tile, handled by Player), and an electric/burner mining drill needs ore in
## its `resource_searching_radius`.  Every other machine may stand on any land
## tile, ore or not.  Ghosts are plans and are deliberately exempt, so a
## blueprint can be laid out before the ground is ready.
func can_place_terrain(entity: Entity) -> bool:
	if entity.is_ghost():
		return true
	if entity.proto_type == "offshore-pump":
		return _offshore_pump_placeable(entity)
	for cell: Vector2i in entity.occupied_cells():
		var tile := tile_at(cell)
		if _is_water_tile(tile):
			return false
	if entity.proto_type == "mining-drill":
		return _drill_has_ore(entity)
	return true


## An offshore pump sits *on* water but only at a shore: the tile under it is
## water and the tile its output pipe points at is land.  Rotating with R picks
## which shore side the output faces.
func _offshore_pump_placeable(entity: Entity) -> bool:
	if entity.occupied_cells().size() != 1:
		return false
	var cell := entity.origin
	if not _is_water_tile(tile_at(cell)):
		return false
	var out_dir := posmod(8 + entity.direction, 16)
	var out_cell := cell + BeltSim.dir_vector(out_dir)
	return not _is_water_tile(tile_at(out_cell))


static func _is_water_tile(tile: String) -> bool:
	return tile.begins_with("water") or tile.begins_with("deepwater")


## Whether a drill has a resource it can mine directly under its footprint.
##
## The rule is intentionally about the footprint, not the wider
## `resource_searching_radius`: a drill placed on bare grass next to an ore
## patch should be refused as "not on ore", which is what the player asked
## for.  Once placed, the simulation may still reach resource in its radius.
func _drill_has_ore(entity: Entity) -> bool:
	var proto := entity.prototype()
	if proto.is_empty():
		return false
	var categories: Array = proto.get("resource_categories", [])
	for cell: Vector2i in entity.occupied_cells():
		var ore := ore_at(cell)
		if str(ore["name"]).is_empty() or float(ore["amount"]) <= 0.0:
			continue
		var resource := Prototypes.get_p("resource", str(ore["name"]))
		if _resource_matches(resource, categories):
			return true
	return false


## The same category matching the simulation uses for a drill's ore.
static func _resource_matches(resource: Dictionary, categories: Array) -> bool:
	if categories.is_empty():
		return true
	var own: Variant = resource.get("resource_categories", [])
	if own is Array:
		for category: Variant in own:
			if categories.has(category):
				return true
	if resource.has("category") and categories.has(str(resource["category"])):
		return true
	var minable: Variant = resource.get("minable", {})
	var category := "basic-solid"
	if minable is Dictionary and minable.has("category"):
		category = str(minable["category"])
	return categories.has(category)


## Factorio decides which half of an underground belt you are placing: if
## there is already a matching half behind, this one is the exit.
func orient_underground(entity: Entity) -> void:
	if entity.proto_type != "underground-belt":
		return
	var proto := entity.prototype()
	var max_distance := int(proto.get("max_distance", 5))
	var back := posmod(entity.direction + 8, 16)
	var step := BeltSim.dir_vector(back)
	for k in range(1, max_distance + 1):
		var other := entity_at(entity.origin + step * k)
		if other == null:
			continue
		if other.proto_type == "underground-belt" and other.name == entity.name \
				and posmod(other.direction, 16) == posmod(entity.direction, 16) \
				and str(other.state.get("io", "input")) == "input":
			entity.state["io"] = "output"
			return
	entity.state["io"] = "input"


func place_entity(entity: Entity) -> bool:
	orient_underground(entity)
	if not entity.is_ghost() and _entity_on_water(entity) \
			and entity.proto_type != "offshore-pump":
		return false
	if not entity.is_ghost() and entity.proto_type == "offshore-pump" \
			and not _offshore_pump_placeable(entity):
		return false
	if not can_place(entity):
		return false
	var cells := entity.occupied_cells()
	entities[entity.origin] = entity
	for cell in cells:
		_entity_owner[cell] = entity
	_index_dirty = true
	InventoryLayout.attach(entity)
	# Everything that can be shot starts at its prototype's health.
	if not entity.state.has("health"):
		var max_health: Variant = entity.prototype().get("max_health")
		if max_health != null:
			entity.state["health"] = float(max_health)
	# Factorio's burner inserter arrives with a small initial fuel charge so
	# it can make its first swings before it has picked up any fuel.
	if not entity.state.has("burn_energy"):
		var energy_source: Variant = entity.prototype().get("energy_source", {})
		if energy_source is Dictionary \
				and str((energy_source as Dictionary).get("type", "")) == "burner":
			var initial_item := str((energy_source as Dictionary).get("initial_fuel", ""))
			var initial_value := Energy.fuel_value(initial_item)
			var initial_ratio := clampf(float((energy_source as Dictionary).get(
				"initial_fuel_percent", 0.0)), 0.0, 1.0)
			if initial_value > 0.0 and initial_ratio > 0.0:
				entity.state["burn_energy"] = initial_value * initial_ratio
	revision += 1
	entity_placed.emit(entity)
	return true


## Whether any cell of an entity is on water.  Nothing physical may spawn
## there; ghosts are plans and are deliberately exempt.
func _entity_on_water(entity: Entity) -> bool:
	for cell: Vector2i in entity.occupied_cells():
		if _is_water_tile(tile_at(cell)):
			return true
	return false


static func is_decorative(entity: Entity) -> bool:
	return entity.proto_type == "tree" or entity.proto_type == "simple-entity"


## Remove natural trees and rocks from an area, used around the starting
## factory before its machines are placed.
func clear_decoratives(area: Rect2i) -> int:
	var victims: Array = []
	for entity: Entity in entities.values():
		if not is_decorative(entity) or entity.is_ghost():
			continue
		if area.intersects(Rect2i(entity.origin, entity.size)):
			victims.append(entity)
	for entity: Entity in victims:
		remove_entity(entity)
	return victims.size()


## Turn a placed entity a quarter turn, keeping its centre where it was.
##
## Footprints can swap width and height (a splitter is 2x1 facing north and
## 1x2 facing east), so the origin is recomputed and every owner cell is moved.
## The turn is refused if the new footprint would overlap another entity or
## water.
func rotate_entity(entity: Entity, new_direction: int) -> bool:
	if entity == null or entity.is_ghost():
		return false
	var old_origin := entity.origin
	var old_cells := entity.occupied_cells()
	var centre := entity.center()
	var new_direction_wrapped := posmod(new_direction, 16)
	var new_size := Entity.footprint(entity.proto_type, entity.name,
		new_direction_wrapped)
	var new_origin := Vector2i(
		int(round(centre.x - float(new_size.x) * 0.5)),
		int(round(centre.y - float(new_size.y) * 0.5)))
	var new_cells: Array[Vector2i] = []
	for y in new_size.y:
		for x in new_size.x:
			var cell := new_origin + Vector2i(x, y)
			var owner: Variant = _entity_owner.get(cell)
			if owner != null and owner != entity:
				return false
			if _is_water_tile(tile_at(cell)):
				return false
			new_cells.append(cell)
	for cell: Vector2i in old_cells:
		if _entity_owner.get(cell) == entity:
			_entity_owner.erase(cell)
	entities.erase(old_origin)
	entity.origin = new_origin
	entity.direction = new_direction_wrapped
	entity.size = new_size
	entities[new_origin] = entity
	for cell: Vector2i in new_cells:
		_entity_owner[cell] = entity
	_index_dirty = true
	revision += 1
	return true


## Move an already placed entity to a new origin without rebuilding it.
##
## Used by the drivable car.  Footprints may move over item-entities and belts
## but not overlapping solid machines, and never onto water.
func move_entity(entity: Entity, new_origin: Vector2i) -> bool:
	if entity == null or entity.is_ghost():
		return false
	if new_origin == entity.origin:
		return true
	var size := entity.size
	var new_cells: Array[Vector2i] = []
	for y in size.y:
		for x in size.x:
			var cell := new_origin + Vector2i(x, y)
			var owner: Variant = _entity_owner.get(cell)
			if owner != null and owner != entity:
				return false
			if _is_water_tile(tile_at(cell)):
				return false
			new_cells.append(cell)
	for cell: Vector2i in entity.occupied_cells():
		if _entity_owner.get(cell) == entity:
			_entity_owner.erase(cell)
	entities.erase(entity.origin)
	entity.origin = new_origin
	entities[new_origin] = entity
	for cell: Vector2i in new_cells:
		_entity_owner[cell] = entity
	_index_dirty = true
	revision += 1
	return true


## Put an entity down as a plan rather than as a machine.
func place_ghost(entity: Entity) -> bool:
	entity.make_ghost(entity.proto_type)
	if not can_place(entity):
		return false
	for cell: Vector2i in entity.occupied_cells():
		_entity_owner[cell] = entity
	entities[entity.origin] = entity
	_index_dirty = true
	revision += 1
	entity_placed.emit(entity)
	return true


## Replace a ghost with the real thing, keeping its tile.
func revive_ghost(ghost: Entity) -> Entity:
	var direction := ghost.direction
	var origin := ghost.origin
	var recipe := str(ghost.state.get("recipe", ""))
	var proto_type := str(ghost.state.get("ghost_of", ghost.proto_type))
	remove_entity(ghost)
	var real := Entity.create(proto_type, ghost.name, origin, direction)
	if not place_entity(real):
		return null
	if not recipe.is_empty():
		real.state["recipe"] = recipe
	return real


## Every ghost in the world, which is what construction robots work through.
func ghosts() -> Array:
	var out: Array = []
	for entity: Entity in entities.values():
		if entity.is_ghost():
			out.append(entity)
	return out


func remove_entity(entity: Entity) -> void:
	entities.erase(entity.origin)
	for cell in entity.occupied_cells():
		if _entity_owner.get(cell) == entity:
			_entity_owner.erase(cell)
	_index_dirty = true
	revision += 1
	entity_removed.emit(entity)


## Entities of one prototype type, e.g. all belts, in placement order.
func entities_of_type(proto_type: String) -> Array:
	if _index_dirty:
		_rebuild_type_index()
	return _type_index.get(proto_type, [])


func _rebuild_type_index() -> void:
	_index_dirty = false
	var index: Dictionary = {}
	for entity: Entity in entities.values():
		if not index.has(entity.proto_type):
			index[entity.proto_type] = []
		(index[entity.proto_type] as Array).append(entity)
	_type_index = index


func entity_types() -> Array:
	if _index_dirty:
		_rebuild_type_index()
	return _type_index.keys()


func entity_at(cell: Vector2i) -> Entity:
	return _entity_owner.get(cell)


func entity_at_origin(cell: Vector2i) -> Entity:
	return entities.get(cell)


func entity_count() -> int:
	return entities.size()


func chunk_count() -> int:
	return _chunks.size()


## Wipe everything, ready for a save to be loaded on top.
func clear_all() -> void:
	_chunks.clear()
	revealed_chunks.clear()
	entities.clear()
	_entity_owner.clear()
	_type_index.clear()
	palette = PackedStringArray()
	_palette_index.clear()
	_cell_stamps.clear()
	_chunk_stamps.clear()
	epoch += 1
	_index_dirty = true
	revision += 1


## Install a chunk verbatim (loading a save, rather than generating).
func install_chunk(coord: Vector2i, loaded: Chunk) -> void:
	loaded.generated = true
	_chunks[coord] = loaded
	_cell_stamps.clear()
	_chunk_stamps.clear()
	epoch += 1
	_index_dirty = true
	revision += 1
