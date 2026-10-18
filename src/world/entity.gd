class_name Entity
extends RefCounted
## One placed object in the world.
##
## ``origin`` is the top-left tile of the entity's footprint in Factorio's
## coordinate convention, and ``direction`` uses the 16-way direction enum so
## values read the same as ``defines.direction``.

var proto_type: String = ""
var name: String = ""
var origin: Vector2i = Vector2i.ZERO
var direction: int = 0
var size: Vector2i = Vector2i.ONE

## Free-form per-entity runtime state (inventories, progress, recipes, ...).
var state: Dictionary = {}

static var _size_cache: Dictionary = {}


static func create(proto_type_: String, name_: String, origin_: Vector2i,
		direction_: int = 0) -> Entity:
	var e := Entity.new()
	e.proto_type = proto_type_
	e.name = name_
	e.origin = origin_
	e.direction = direction_
	e.size = footprint(proto_type_, name_, direction_)
	return e


## Footprint in tiles, derived from the prototype's collision box the same way
## Factorio does: the box size rounded *up*, minimum one tile.  Factorio's
## stone furnace, for example, has a 1.4 tile box and occupies 2x2.
## Ground footprint of a prototype, in tiles.
##
## The collision box is given in the entity's own frame, so a facing that has
## turned a quarter turn swaps the two sides — a splitter is two tiles wide
## when it points north and two tiles tall when it points east.
static func footprint(proto_type_: String, name_: String, direction_: int = 0) -> Vector2i:
	var quarter := posmod(direction_, 16) in [4, 12]
	var key := "%s/%s/%s" % [proto_type_, name_, "q" if quarter else "s"]
	if _size_cache.has(key):
		return _size_cache[key]
	var proto := Prototypes.get_p(proto_type_, name_)
	var tiles := Vector2i.ONE
	# Offshore pumps declare a 1x1 tile footprint even though their drawing and
	# collision box are taller; using the collision box made them 2x2 and the
	# output pipe tile was blocked by the pump itself.
	var tile_w := int(proto.get("tile_width", 0))
	var tile_h := int(proto.get("tile_height", 0))
	if tile_w > 0 and tile_h > 0:
		tiles = Vector2i(tile_w, tile_h)
	var box: Variant = proto.get("collision_box")
	if (tile_w <= 0 or tile_h <= 0) and box is Array and box.size() == 2:
		var a := FactorioAssets.parse_vector(box[0])
		var b := FactorioAssets.parse_vector(box[1])
		tiles = Vector2i(
			maxi(1, int(ceil(absf(b.x - a.x)))),
			maxi(1, int(ceil(absf(b.y - a.y)))))
		if quarter:
			tiles = Vector2i(tiles.y, tiles.x)
	_size_cache[key] = tiles
	return tiles


func prototype() -> Dictionary:
	return Prototypes.get_p(proto_type, name)


## A ghost is a plan: the entity is not built yet, nothing simulates it, and a
## real one placed on top of it takes its place.
func is_ghost() -> bool:
	return bool(state.get("ghost", false))


func make_ghost(blueprint_of: String) -> void:
	state["ghost"] = true
	state["ghost_of"] = blueprint_of
	state.erase("inventories")
	state.erase("fluids")


func occupied_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in size.y:
		for x in size.x:
			out.append(origin + Vector2i(x, y))
	return out


## Centre of the entity in tile coordinates.
func center() -> Vector2:
	return Vector2(origin) + Vector2(size) * 0.5


func is_valid() -> bool:
	return not prototype().is_empty()


func get_state(key: String, fallback: Variant = null) -> Variant:
	return state.get(key, fallback)


func set_state(key: String, value: Variant) -> void:
	state[key] = value
