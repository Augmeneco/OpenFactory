extends Node
## Central registry over the Factorio prototype database.
##
## The database is produced by ``tools/factorio_extract/`` — it runs the real
## Factorio data stage and converts ``data.raw`` into per-type JSON files under
## ``res://assets/data/prototypes/``.  Types are loaded lazily so start-up only
## pays for what the game actually touches.

const DATA_DIR := "res://assets/data"
const PROTO_DIR := DATA_DIR + "/prototypes"
## Optional bundled copy of Factorio's data/ tree, used by exported builds.
const PACKED_FACTORIO_ROOT := "res://factorio_data"
const PACKED_MARKER := PACKED_FACTORIO_ROOT + "/packed_data.marker"

## Parsed ``manifest.json``: provenance plus a per-type index.
var manifest: Dictionary = {}
## Absolute path to the Factorio installation root (``.../common/Factorio``).
var factorio_root: String = ""
## Absolute path to Factorio's ``data`` directory holding the mod folders.
var data_path: String = ""

var _types: Dictionary = {}        ## prototype type -> { name: prototype }
var _failed: Dictionary = {}       ## prototype type -> error string
## Space Age / Quality DLC content is filtered out: the project targets the
## base 2.0 game, and those prototypes otherwise leak into the item picker and
## the crafting menu.
var _dlc_items_ready := false
var _dlc_items: Dictionary = {}
var _dlc_recipes_ready := false
var _dlc_recipes: Dictionary = {}

signal type_loaded(proto_type: String)


func _ready() -> void:
	_load_manifest()


func _load_manifest() -> void:
	var text := FileAccess.get_file_as_string(DATA_DIR + "/manifest.json")
	if text.is_empty():
		push_error("Prototypes: manifest.json is missing. Run tools/factorio_extract/convert.py")
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		manifest = parsed
		factorio_root = manifest.get("factorio_root", "")
		data_path = factorio_root.path_join("data")
	_apply_override()


## The install path is machine specific, so it can be overridden by a project
## setting (and is auto-detected from the dump as a fallback).
func _apply_override() -> void:
	# An exported build carries the needed Factorio data inside the PCK; that
	# copy wins over the machine-specific absolute path baked into project.godot.
	var packed_data := PACKED_FACTORIO_ROOT.path_join("data")
	if FileAccess.file_exists(PACKED_MARKER):
		factorio_root = PACKED_FACTORIO_ROOT
		data_path = packed_data
		return
	var override: String = ProjectSettings.get_setting("openfactory/factorio_root", "")
	if not override.is_empty():
		factorio_root = override
		data_path = factorio_root.path_join("data")
	if not DirAccess.dir_exists_absolute(data_path):
		push_warning("Prototypes: Factorio data directory not found at '%s'" % data_path)


# --------------------------------------------------------------------------
# type access
# --------------------------------------------------------------------------

func has_type(proto_type: String) -> bool:
	return manifest.get("types", {}).has(proto_type)


## Load one prototype type.  Returns ``{ name: prototype }`` (empty on failure).
func all(proto_type: String) -> Dictionary:
	if _types.has(proto_type):
		return _types[proto_type]
	if _failed.has(proto_type):
		return {}
	if not has_type(proto_type):
		_failed[proto_type] = "unknown type"
		return {}
	var path := "%s/%s.json" % [PROTO_DIR, proto_type]
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		_failed[proto_type] = "missing file " + path
		push_error("Prototypes: cannot read " + path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_failed[proto_type] = "malformed JSON"
		push_error("Prototypes: malformed JSON in " + path)
		return {}
	parsed = _filter_dlc(proto_type, parsed as Dictionary)
	_types[proto_type] = parsed
	type_loaded.emit(proto_type)
	return parsed


## Read one prototype file without caching or DLC filtering.  Used only to
## build the filter sets, so it cannot recurse through ``all()``.
func _raw_type(proto_type: String) -> Dictionary:
	var path := "%s/%s.json" % [PROTO_DIR, proto_type]
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed as Dictionary if parsed is Dictionary else {}


static func _has_dlc_asset(proto: Dictionary) -> bool:
	var icon: Variant = proto.get("icon", "")
	if icon is String and ("__space-age__" in icon or "__quality__" in icon):
		return true
	var icons: Variant = proto.get("icons", [])
	if icons is Array:
		for entry: Variant in icons:
			if entry is Dictionary:
				var path := str((entry as Dictionary).get("icon", ""))
				if "__space-age__" in path or "__quality__" in path:
					return true
	return false


func _dlc_item_names() -> Dictionary:
	if _dlc_items_ready:
		return _dlc_items
	_dlc_items_ready = true
	for proto_type: String in ITEM_LIKE_TYPES:
		var raw := _raw_type(proto_type)
		for name: String in raw:
			var proto: Variant = raw[name]
			if proto is Dictionary and _has_dlc_asset(proto as Dictionary):
				_dlc_items[name] = true
	# Every equipment kind is its own prototype type.
	for proto_type: String in EQUIPMENT_TYPES:
		var raw_equipment := _raw_type(proto_type)
		for name: String in raw_equipment:
			var proto: Variant = raw_equipment[name]
			if proto is Dictionary and _has_dlc_asset(proto as Dictionary):
				_dlc_items[name] = true
	# Space Age's item group is DLC even when an icon happens to live in base.
	var subs := _raw_type("item-subgroup")
	for proto_type: String in ITEM_LIKE_TYPES:
		var raw_group := _raw_type(proto_type)
		for name: String in raw_group:
			var proto: Variant = raw_group[name]
			if not (proto is Dictionary):
				continue
			var sg: Variant = subs.get(str((proto as Dictionary).get("subgroup", "")))
			if sg is Dictionary and str((sg as Dictionary).get("group", "")) == "space":
				_dlc_items[name] = true
	return _dlc_items


func _dlc_recipe_names() -> Dictionary:
	if _dlc_recipes_ready:
		return _dlc_recipes
	_dlc_recipes_ready = true
	var items := _dlc_item_names()
	var raw := _raw_type("recipe")
	for name: String in raw:
		var recipe: Variant = raw[name]
		if not (recipe is Dictionary):
			continue
		var dict := recipe as Dictionary
		if _has_dlc_asset(dict):
			_dlc_recipes[name] = true
			continue
		var touched := false
		for key: String in ["products", "ingredients", "results"]:
			var list: Variant = dict.get(key, [])
			if not (list is Array):
				continue
			for entry: Variant in list:
				if entry is Dictionary:
					if items.has(str((entry as Dictionary).get("name", ""))):
						touched = true
				elif entry is Array and not (entry as Array).is_empty() \
						and items.has(str((entry as Array)[0])):
					touched = true
		if touched:
			_dlc_recipes[name] = true
	return _dlc_recipes


func _filter_dlc(proto_type: String, parsed: Dictionary) -> Dictionary:
	if ITEM_LIKE_TYPES.has(proto_type) or EQUIPMENT_TYPES.has(proto_type):
		var items := _dlc_item_names()
		for name: String in items:
			parsed.erase(name)
		return parsed
	if proto_type == "recipe":
		var recipes := _dlc_recipe_names()
		for name: String in recipes:
			parsed.erase(name)
		return parsed
	if proto_type == "technology":
		var recipes := _dlc_recipe_names()
		for name: String in parsed.keys():
			var tech: Variant = parsed[name]
			if not (tech is Dictionary):
				continue
			var dict := tech as Dictionary
			if _has_dlc_asset(dict):
				parsed.erase(name)
				continue
			var unlocks: Variant = dict.get("unlocks", [])
			if unlocks is Array:
				for unlock: Variant in unlocks:
					if unlock is Dictionary \
							and recipes.has(str((unlock as Dictionary).get("recipe", ""))):
						parsed.erase(name)
						break
		return parsed
	if proto_type == "resource":
		for name: String in parsed.keys():
			var res: Variant = parsed[name]
			if res is Dictionary and _has_dlc_asset(res as Dictionary):
				parsed.erase(name)
		return parsed
	return parsed


## Fetch a single prototype, or an empty dictionary when it does not exist.
func get_p(proto_type: String, name: String) -> Dictionary:
	var bucket: Dictionary = all(proto_type)
	var entry: Variant = bucket.get(name)
	if entry is Dictionary:
		return entry
	return {}


func has(proto_type: String, name: String) -> bool:
	return all(proto_type).has(name)


func names(proto_type: String) -> Array:
	return all(proto_type).keys()


func count(proto_type: String) -> int:
	return all(proto_type).size()


## Every loaded type name, e.g. ``["item", "recipe", ...]``.
func type_names() -> Array:
	return manifest.get("types", {}).keys()


# --------------------------------------------------------------------------
# convenience lookups used all over the game code
# --------------------------------------------------------------------------

## ``{ name, amount }`` ingredient list of a recipe, normalised from
## Factorio's two possible shapes (``ingredients`` entries as dictionaries or
## as ``[name, amount]`` pairs).  JSON numbers arrive as floats, so every
## amount is coerced back to an integer.
static func recipe_ingredients(recipe: Dictionary) -> Array:
	var out: Array = []
	for ing in recipe.get("ingredients", []):
		if ing is Dictionary:
			var entry := {"name": str(ing.get("name", "")),
				"amount": int(ing.get("amount", 0)),
				"type": str(ing.get("type", "item"))}
			# Fluid ingredients name the machine's fluid box they belong to.
			if ing.has("fluidbox_index"):
				entry["fluidbox_index"] = int(ing["fluidbox_index"])
			out.append(entry)
		elif ing is Array and ing.size() >= 2:
			out.append({"name": str(ing[0]), "amount": int(ing[1]), "type": "item"})
	return out


static func recipe_products(recipe: Dictionary) -> Array:
	var out: Array = []
	for res in recipe.get("results", []):
		if res is Dictionary:
			var entry := {"name": str(res.get("name", "")),
				"amount": int(res.get("amount", 1)),
				"type": str(res.get("type", "item")),
				"probability": float(res.get("probability", 1.0))}
			if res.has("fluidbox_index"):
				entry["fluidbox_index"] = int(res["fluidbox_index"])
			out.append(entry)
	if out.is_empty() and recipe.has("result"):
		out.append({"name": str(recipe.get("result", "")),
			"amount": int(recipe.get("result_count", 1)),
			"type": "item", "probability": 1.0})
	return out


## Seconds a recipe takes in a machine of crafting speed 1.
## Factorio omits ``energy_required`` when it equals its documented default.
static func recipe_energy(recipe: Dictionary) -> float:
	return float(recipe.get("energy_required", 0.5))


## Prototype types that behave like items in an inventory.
##
## Factorio splits them up: science packs are ``tool``, grenades are
## ``capsule``, modules and ammo have their own types.  Anything that can sit
## in a slot is listed here, in the order lookups should prefer.
const ITEM_LIKE_TYPES := [
	"item", "tool", "capsule", "module", "ammo", "gun", "armor",
	"repair-tool", "mining-tool", "selection-tool", "blueprint",
	"blueprint-book", "deconstruction-item", "upgrade-item", "rail-planner",
	"spidertron-remote", "item-with-entity-data", "item-with-tags",
	"item-with-label", "item-with-inventory", "space-platform-starter-pack",
]


## The prototype for anything that can live in an inventory slot, whatever
## its concrete type is.
func item_proto(item_name: String) -> Dictionary:
	for proto_type: String in ITEM_LIKE_TYPES:
		var entry := get_p(proto_type, item_name)
		if not entry.is_empty():
			return entry
	return {}


## Every prototype type that represents something standing in the world.
const ENTITY_TYPES := [
	"straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail",
	"elevated-straight-rail", "elevated-curved-rail-a", "elevated-curved-rail-b",
	"elevated-half-diagonal-rail", "rail-ramp", "rail-support", "train-stop",
	"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon",
	"transport-belt", "underground-belt", "splitter", "inserter",
	"mining-drill", "offshore-pump", "furnace", "assembling-machine",
	"rocket-silo", "container", "logistic-container", "electric-pole",
	"solar-panel", "generator", "boiler", "accumulator", "reactor", "pipe",
	"pipe-to-ground", "pump", "storage-tank", "lab", "ammo-turret",
	"electric-turret", "artillery-turret", "wall", "gate", "radar", "roboport",
	"beacon", "arithmetic-combinator", "decider-combinator",
	"constant-combinator", "programmable-speaker", "car", "spider-vehicle",
	"tree", "simple-entity", "resource", "unit-spawner", "turret", "land-mine",
	"heat-pipe", "reactor", "lightning-attractor", "proxy-container",
	"linked-container", "display-panel", "item-entity", "character",
	"combat-robot", "construction-robot", "logistic-robot", "rocket",
	"cargo-pod", "spider-leg", "corpse", "artillery-projectile",
]


## The prototype type a name lives under, preferring the ones that stand in
## the world — "land-mine" is both an item and a thing you put down.
func entity_type_of(name: String) -> String:
	for proto_type: String in ENTITY_TYPES:
		if has(proto_type, name):
			return proto_type
	for proto_type: String in _types:
		if has(proto_type, name) and not ITEM_LIKE_TYPES.has(proto_type):
			return proto_type
	return ""


## Equipment is not one prototype type: every kind — a shield, a battery, an
## exoskeleton — is its own type, so a name has to be searched for across them.
const EQUIPMENT_TYPES := ["active-defense-equipment",
	"battery-equipment", "belt-immunity-equipment",
	"energy-shield-equipment", "generator-equipment",
	"inventory-bonus-equipment", "movement-bonus-equipment",
	"night-vision-equipment", "roboport-equipment",
	"solar-panel-equipment"]


## The prototype for a piece of equipment, whatever its concrete type.
func equipment_proto(equipment_name: String) -> Dictionary:
	for proto_type: String in EQUIPMENT_TYPES:
		var entry := get_p(proto_type, equipment_name)
		if not entry.is_empty():
			return entry
	return {}


func is_equipment(equipment_name: String) -> bool:
	return not equipment_proto(equipment_name).is_empty()


## The prototype type of an item-like name, or "" when there is none.
func item_type(item_name: String) -> String:
	for proto_type: String in ITEM_LIKE_TYPES:
		if has(proto_type, item_name):
			return proto_type
	return ""


## Whether a name can be carried in an inventory.
func is_item(item_name: String) -> bool:
	return not item_type(item_name).is_empty()


## Probe whether a prototype stacks in inventories, and how high.
func stack_size(name: String) -> int:
	var item := item_proto(name)
	if not item.is_empty():
		return int(item.get("stack_size", 50))
	return 1


## Subgroup ordering used to sort inventories and the crafting menu the same
## way Factorio does.
func subgroup_order(subgroup: String) -> String:
	var sg := get_p("item-subgroup", subgroup)
	return str(sg.get("order", "z"))


## One sortable key for an item: group order, then subgroup order, then the
## item's own order inside the subgroup, exactly the order Factorio uses in
## inventories and its item picker.
## Broad item group (logistics, production, intermediate-products, combat...).
func item_group(item_name: String) -> String:
	var item := item_proto(item_name)
	if item.is_empty():
		return ""
	var subgroup := get_p("item-subgroup", str(item.get("subgroup", "")))
	return str(subgroup.get("group", ""))


func item_sort_key(item_name: String) -> String:
	var item := item_proto(item_name)
	if item.is_empty():
		return "z/z/z/%s" % item_name
	var subgroup_name := str(item.get("subgroup", ""))
	var subgroup := get_p("item-subgroup", subgroup_name)
	var group_name := str(subgroup.get("group", ""))
	var group := get_p("item-group", group_name)
	var group_order := str(group.get("order", "z"))
	var subgroup_order_value := str(subgroup.get("order", "z"))
	var item_order := str(item.get("order", "z"))
	return "%s/%s/%s/%s" % [group_order, subgroup_order_value,
		item_order, item_name]


var _recipes_by_category: Dictionary = {}


## Recipe names of one crafting category, built once on first use.
func recipes_in_category(category: String) -> Array:
	if _recipes_by_category.is_empty():
		for recipe_name: String in names("recipe"):
			var recipe := get_p("recipe", recipe_name)
			var key := str(recipe.get("category", "crafting"))
			if not _recipes_by_category.has(key):
				_recipes_by_category[key] = []
			(_recipes_by_category[key] as Array).append(recipe_name)
	return _recipes_by_category.get(category, [])
