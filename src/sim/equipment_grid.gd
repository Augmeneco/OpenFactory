class_name EquipmentGrid
extends RefCounted
## A power armour's grid, and the equipment in it.
##
## The grid is a plain rectangle of cells and every piece of equipment is a
## rectangle inside it, so placing one is a search for a free block.  What the
## equipment then *does* is read from its prototype — an exoskeleton carries a
## `movement_bonus`, a shield a `max_shield_value`, a roboport a
## `construction_radius` — so adding a new kind needs no code here.

## The armour the grid belongs to, or "" for a bare engineer.
var armor := ""
var width := 0
var height := 0
## ``[{ name, x, y, energy }]`` in grid cells.
var items: Array = []
## The engineering's own shield charge, topped up from the equipment.
var shield := 0.0
var max_shield := 0.0


func stats() -> Dictionary:
	var counts: Dictionary = {}
	for item: Dictionary in items:
		var name := str(item["name"])
		counts[name] = int(counts.get(name, 0)) + 1
	return {"armor": armor, "width": width, "height": height,
		"items": items.size(), "counts": counts,
		"max_shield": max_shield, "shield": shield}


## The grid's size, taken from the armour prototype's `equipment_grid`.
func set_armor(armor_name: String) -> void:
	armor = armor_name
	items.clear()
	shield = 0.0
	max_shield = 0.0
	if armor_name.is_empty():
		width = 0
		height = 0
		return
	var proto := Prototypes.get_p("armor", armor_name)
	var grid_name := str(proto.get("equipment_grid", ""))
	var grid := Prototypes.get_p("equipment-grid", grid_name)
	width = int(grid.get("width", 0))
	height = int(grid.get("height", 0))
	max_shield = _shield_capacity()
	shield = max_shield


# --------------------------------------------------------------------------
# placing
# --------------------------------------------------------------------------

## The footprint of a piece of equipment, from its prototype's `shape`.
static func shape_of(name: String) -> Vector2i:
	var proto := Prototypes.equipment_proto(name)
	var shape: Variant = proto.get("shape", {})
	if shape is Dictionary:
		return Vector2i(maxi(1, int((shape as Dictionary).get("width", 1))),
			maxi(1, int((shape as Dictionary).get("height", 1))))
	return Vector2i.ONE


## Whether a piece fits with its top-left corner at a cell.
func fits(name: String, at: Vector2i) -> bool:
	var size := shape_of(name)
	if size.x <= 0 or at.x < 0 or at.y < 0:
		return false
	if at.x + size.x > width or at.y + size.y > height:
		return false
	for item: Dictionary in items:
		var other_size := shape_of(str(item["name"]))
		var other := Vector2i(int(item["x"]), int(item["y"]))
		if _overlaps(at, size, other, other_size):
			return false
	return true


static func _overlaps(a: Vector2i, a_size: Vector2i, b: Vector2i,
		b_size: Vector2i) -> bool:
	return a.x < b.x + b_size.x and b.x < a.x + a_size.x \
		and a.y < b.y + b_size.y and b.y < a.y + a_size.y


## Put a piece of equipment somewhere it fits.  Returns where, or ``(-1,-1)``.
func place(name: String) -> Vector2i:
	for y in height:
		for x in width:
			var at := Vector2i(x, y)
			if fits(name, at):
				insert(name, at)
				return at
	return Vector2i(-1, -1)


## Put a piece at a particular cell, which is what dragging one in does.
func insert(name: String, at: Vector2i) -> bool:
	if not fits(name, at):
		return false
	items.append({"name": name, "x": at.x, "y": at.y, "energy": 0.0})
	max_shield = _shield_capacity()
	shield = minf(shield + _shield_capacity(name), _shield_capacity())
	return true


## The equipment sitting on a cell, if any.
func at_cell(cell: Vector2i) -> Dictionary:
	for item: Dictionary in items:
		var size := shape_of(str(item["name"]))
		var origin := Vector2i(int(item["x"]), int(item["y"]))
		if cell.x >= origin.x and cell.x < origin.x + size.x \
				and cell.y >= origin.y and cell.y < origin.y + size.y:
			return item
	return {}


func remove_at(cell: Vector2i) -> String:
	var item := at_cell(cell)
	if item.is_empty():
		return ""
	items.erase(item)
	max_shield = _shield_capacity()
	shield = minf(shield, max_shield)
	return str(item["name"])


func count_of(name: String) -> int:
	var total := 0
	for item: Dictionary in items:
		if str(item["name"]) == name:
			total += 1
	return total


# --------------------------------------------------------------------------
# what the equipment does
# --------------------------------------------------------------------------

## Every effect the equipment in the grid adds up to.
##
## The keys are the ones the rest of the game asks about, so a caller never has
## to know which piece of equipment produced them.
func effects() -> Dictionary:
	var out := {
		"movement_bonus": 0.0,
		"max_shield": 0.0,
		"shield_recharge": 0.0,
		"construction_radius": 0.0,
		"robot_limit": 0,
		"night_vision": false,
		"belt_immunity": false,
		"inventory_bonus": 0,
		"laser_defense": 0,
		"generation": 0.0,
		"consumption": 0.0,
		"buffer": 0.0,
	}
	for item: Dictionary in items:
		var proto := Prototypes.equipment_proto(str(item["name"]))
		if proto.is_empty():
			continue
		out["movement_bonus"] = float(out["movement_bonus"]) \
			+ float(proto.get("movement_bonus", 0.0))
		out["max_shield"] = float(out["max_shield"]) \
			+ float(proto.get("max_shield_value", 0.0))
		out["construction_radius"] = maxf(float(out["construction_radius"]),
			float(proto.get("construction_radius", 0.0)))
		out["robot_limit"] = maxi(int(out["robot_limit"]),
			int(proto.get("robot_limit", 0)))
		if proto.has("darkness_to_turn_on"):
			out["night_vision"] = true
		if str(item["name"]).begins_with("belt-immunity"):
			out["belt_immunity"] = true
		if proto.has("inventory_size_bonus"):
			out["inventory_bonus"] = int(out["inventory_bonus"]) \
				+ int(proto.get("inventory_size_bonus", 0))
		if proto.has("attack_parameters") \
				and str(item["name"]).contains("laser"):
			out["laser_defense"] = int(out["laser_defense"]) + 1
		# Power: a generator adds, a consumer draws, a battery holds.
		var source: Variant = proto.get("energy_source", {})
		if source is Dictionary:
			var settings: Dictionary = source
			var priority := str(settings.get("usage_priority", ""))
			if priority == "primary-output":
				out["generation"] = float(out["generation"]) \
					+ Energy.parse(proto.get("power"), 0.0)
			if settings.has("buffer_capacity"):
				out["buffer"] = float(out["buffer"]) \
					+ Energy.parse(settings.get("buffer_capacity"), 0.0)
			if priority == "secondary-input":
				out["consumption"] = float(out["consumption"]) \
					+ Energy.parse(proto.get("energy_consumption"), 0.0)
	return out


## The shield the equipment can hold, straight from the prototypes.
func _shield_capacity(extra := "") -> float:
	var total := 0.0
	for item: Dictionary in items:
		total += float(Prototypes.equipment_proto(
			str(item["name"])).get("max_shield_value", 0.0))
	if not extra.is_empty():
		total += float(Prototypes.equipment_proto(
			extra).get("max_shield_value", 0.0))
	return total


## Take a hit on the shield first, and only then on the engineer.
##
## Returns how much still has to be taken out of health.
func absorb(amount: float) -> float:
	if shield <= 0.0:
		return amount
	var taken := minf(shield, amount)
	shield -= taken
	return amount - taken


## Put the shield back up, at the rate the equipment can manage.
func recharge(delta_seconds: float) -> void:
	max_shield = _shield_capacity()
	if shield >= max_shield:
		return
	# Factorio recharges faster the more shields are fitted, and slower while
	# they are being hit; a straight linear rate is close enough to both.
	var rate := 6.0 * maxf(1.0, float(effect_count("energy-shield")))
	shield = minf(max_shield, shield + rate * delta_seconds)


func effect_count(prefix: String) -> int:
	var total := 0
	for item: Dictionary in items:
		if str(item["name"]).begins_with(prefix):
			total += 1
	return total


# --------------------------------------------------------------------------
# serialisation
# --------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {"armor": armor, "shield": shield,
		"items": items.duplicate(true)}


func from_dict(data: Dictionary) -> void:
	set_armor(str(data.get("armor", "")))
	items.clear()
	for entry: Variant in data.get("items", []):
		if entry is Dictionary:
			items.append((entry as Dictionary).duplicate(true))
	max_shield = _shield_capacity()
	shield = clampf(float(data.get("shield", max_shield)), 0.0, max_shield)
