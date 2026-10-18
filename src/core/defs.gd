extends Node
## Access to Factorio's ``defines`` enums.
##
## Values come from ``doc-html/runtime-api.json`` shipped with the game, so
## they are the real numeric constants — ``Defs.direction.north`` is 0,
## ``Defs.direction.east`` is 4, and so on.  Enums are exposed as dictionaries
## through ``_get`` so call sites read exactly like the Lua originals.

var _enums: Dictionary = {}


func _ready() -> void:
	var text := FileAccess.get_file_as_string("res://assets/data/defines.json")
	if text.is_empty():
		push_error("Defs: defines.json missing; run tools/factorio_extract/convert.py")
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		_enums = parsed


## Dynamic property access: ``Defs.direction`` -> ``{ "north": 0, ... }``.
func _get(property: StringName) -> Variant:
	if _enums.has(property):
		return _enums[property]
	return null


## All values of one enum, e.g. ``get_enum("direction")``.
## (``namespace`` is a reserved word in GDScript.)
func get_enum(ns: String) -> Dictionary:
	return _enums.get(ns, {})


func value_of(ns: String, key: String, fallback: int = -1) -> int:
	var table: Dictionary = _enums.get(ns, {})
	return int(table.get(key, fallback))


func has_namespace(ns: String) -> bool:
	return _enums.has(ns)


# --------------------------------------------------------------------------
# direction helpers -- Factorio's 16-way direction enum, used everywhere
# --------------------------------------------------------------------------

const DIRECTION_COUNT := 16


## Convert a direction enum value to a unit vector, matching Factorio's
## convention (+x right, +y down, north = up).
static func dir_to_vector(direction: int) -> Vector2:
	var step := direction % DIRECTION_COUNT
	if step < 0:
		step += DIRECTION_COUNT
	# Each step is 22.5 degrees, clockwise from north.
	var angle := deg_to_rad(step * 22.5 - 90.0)
	return Vector2(round(cos(angle)), round(sin(angle)))


## Factorio stores entity orientation as a float in [0,1) turning clockwise
## from north; this converts it to the 16-way direction enum.
static func orientation_to_direction(orientation: float) -> int:
	var o := fposmod(orientation, 1.0)
	return int(round(o * DIRECTION_COUNT)) % DIRECTION_COUNT


static func direction_to_orientation(direction: int) -> float:
	return float(fposmod(direction, DIRECTION_COUNT)) / DIRECTION_COUNT
