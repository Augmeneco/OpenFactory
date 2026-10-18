class_name Alerts
extends RefCounted
## The alert list Factorio shows down the right-hand edge.
##
## The game watches every machine and raises an icon when something is wrong:
## a burner has run out of coal, a turret is out of ammunition, a machine has
## no power, an output is full, biters have arrived, something was destroyed.
## This walks the world on a slow clock — every half second, not every tick —
## and builds the same list, so the panel can draw it and a click can jump the
## camera to the machine that is complaining.

const NO_POWER := "no-power"
const NO_FUEL := "no-fuel"
const NO_AMMO := "no-ammo"
const NO_FLUID := "no-fluid"
const OUTPUT_FULL := "output-full"
const DESTROYED := "destroyed"
const ENEMIES := "enemies"

## The real icon each alert uses, straight out of ``__core__``.
const ICONS := {
	NO_POWER: "__core__/graphics/icons/alerts/electricity-icon-red.png",
	NO_FUEL: "__core__/graphics/icons/alerts/fuel-icon-red.png",
	NO_AMMO: "__core__/graphics/icons/alerts/ammo-icon-red.png",
	NO_FLUID: "__core__/graphics/icons/alerts/fluid-icon-red.png",
	OUTPUT_FULL: "__core__/graphics/icons/alerts/destination-full-icon.png",
	DESTROYED: "__core__/graphics/icons/alerts/destroyed-icon.png",
	ENEMIES: "__core__/graphics/icons/alerts/danger-icon.png",
}

## How the panel orders them: what stops production first.
const ORDER := [ENEMIES, DESTROYED, NO_POWER, NO_FLUID, NO_FUEL, NO_AMMO,
	OUTPUT_FULL]

const TITLES := {
	NO_POWER: "No power",
	NO_FUEL: "No fuel",
	NO_AMMO: "No ammunition",
	NO_FLUID: "Missing fluid",
	OUTPUT_FULL: "Output full",
	DESTROYED: "Destroyed",
	ENEMIES: "Enemies nearby",
}

## How often the world is walked, in ticks.
const SCAN_TICKS := 30
## How long a wreck stays on the list.
const DESTROYED_TICKS := 600
## How close a biter has to be to the engineer to raise the danger icon.
const DANGER_RANGE := 25.0

## ``[{ kind, cell, entity, message }]``, newest scan.
var items: Array = []
## Wrecks, which fade out rather than clearing immediately.
var _wrecks: Array = []
## ``-SCAN_TICKS`` so the very first update populates the list.
var _scanned := -SCAN_TICKS


## Forget the previous world's alerts.  Loading a save can move ``sim.tick``
## backwards, and the old scan tick/items would otherwise suppress every scan
## for minutes and keep showing obsolete "no power" icons.
func reset() -> void:
	items.clear()
	_wrecks.clear()
	_scanned = -SCAN_TICKS


## Note a wreck for the next few seconds.
func on_destroyed(entity: Entity) -> void:
	_wrecks.append({"cell": entity.origin, "name": entity.name, "age": 0})


## Rebuild the list if enough ticks have passed.  Returns true when it changed.
func update(world: GameWorld, sim: Simulation) -> bool:
	for wreck: Dictionary in _wrecks:
		wreck["age"] = int(wreck["age"]) + 1
	_wrecks = _wrecks.filter(func(w: Dictionary) -> bool:
		return int(w["age"]) < DESTROYED_TICKS)

	if sim.tick < _scanned:
		# A loaded save went back in time; force a fresh scan immediately.
		_scanned = sim.tick - SCAN_TICKS
	if sim.tick - _scanned < SCAN_TICKS:
		return false
	_scanned = sim.tick
	items = _scan(world, sim)
	return true


func _scan(world: GameWorld, sim: Simulation) -> Array:
	var found: Array = []
	for entity: Entity in world.entities.values():
		if entity.is_ghost():
			continue
		var proto := entity.prototype()
		if proto.is_empty():
			continue
		if _is_unpowered(entity, proto, sim):
			found.append(_entry(NO_POWER, entity,
				"%s has no power" % Loc.proto_display_name(proto, entity.name)))
		if _is_out_of_fuel(entity, proto, sim):
			found.append(_entry(NO_FUEL, entity,
				"%s is out of fuel" % Loc.proto_display_name(proto, entity.name)))
		if _is_out_of_ammo(entity, proto):
			found.append(_entry(NO_AMMO, entity,
				"%s is out of ammunition" % Loc.proto_display_name(proto, entity.name)))
		if _is_missing_fluid(entity, sim):
			found.append(_entry(NO_FLUID, entity,
				"%s is missing a fluid" % Loc.proto_display_name(proto, entity.name)))
		if _is_output_full(entity, proto):
			found.append(_entry(OUTPUT_FULL, entity,
				"%s has a full output" % Loc.proto_display_name(proto, entity.name)))

	for wreck: Dictionary in _wrecks:
		var name := Loc.proto_name("item", str(wreck["name"])) \
			if Prototypes.is_item(str(wreck["name"])) else str(wreck["name"])
		found.append({
			"kind": DESTROYED, "cell": wreck["cell"], "entity": null,
			"message": "%s was destroyed" % name,
		})

	found.append_array(_enemy_alerts(sim))
	return found


static func _entry(kind: String, entity: Entity, message: String) -> Dictionary:
	return {"kind": kind, "cell": entity.origin, "entity": entity,
		"message": message}


## A machine that draws power and is getting none.
func _is_unpowered(entity: Entity, proto: Dictionary, sim: Simulation) -> bool:
	if Energy.usage(proto) <= 0.0 or Energy.is_burner(proto):
		return false
	if not Energy.is_electric(proto):
		return false
	if entity.proto_type in ["solar-panel", "accumulator", "electric-pole",
			"generator", "roboport"]:
		return false
	# A machine that has never been wired up reads as unsatisfied too, which is
	# exactly what the player wants to be told.
	return sim.power.satisfaction_for(entity) <= 0.0


func _is_out_of_fuel(entity: Entity, proto: Dictionary, sim: Simulation) -> bool:
	if not Energy.is_burner(proto):
		return false
	var fuel := InventoryLayout.get_inventory(entity, InventoryLayout.FUEL)
	if fuel == null or not fuel.is_empty():
		return false
	if float(entity.state.get("burn_energy", 0.0)) > 0.0:
		return false
	# Only complain when the machine actually has something to do.
	if entity.proto_type == "boiler":
		return true
	if entity.proto_type == "furnace":
		var input := InventoryLayout.get_inventory(entity, InventoryLayout.INPUT)
		return input != null and not input.is_empty()
	if entity.proto_type == "mining-drill":
		# A drill with no ore under it has nothing to burn fuel for.
		return not sim.has_ore_under(entity).is_empty()
	return true


func _is_out_of_ammo(entity: Entity, proto: Dictionary) -> bool:
	if entity.proto_type != "ammo-turret":
		return false
	var category := str(proto.get("attack_parameters", {}).get(
		"ammo_category", "bullet"))
	var magazine := InventoryLayout.get_inventory(entity, InventoryLayout.FUEL)
	if magazine == null:
		return true
	for slot: Variant in magazine.slots:
		if slot == null:
			continue
		var ammo := Prototypes.get_p("ammo", str(slot["name"]))
		if not ammo.is_empty() \
				and str(ammo.get("ammo_category", "")) == category:
			return false
	return true


## A crafting machine whose recipe names a fluid it has not got.
func _is_missing_fluid(entity: Entity, sim: Simulation) -> bool:
	if entity.proto_type not in ["assembling-machine", "furnace", "chemical-plant"]:
		return false
	var recipe_name := str(entity.state.get("recipe", ""))
	if recipe_name.is_empty():
		return false
	var recipe := Prototypes.get_p("recipe", recipe_name)
	for ingredient: Dictionary in Prototypes.recipe_ingredients(recipe):
		if str(ingredient.get("type", "item")) != "fluid":
			continue
		var box := Simulation.fluid_box_for(entity, ingredient)
		if box.is_empty():
			continue
		if str(sim.fluids.aggregate(entity, box)["fluid"]) \
				!= str(ingredient["name"]):
			return true
	return false


## A machine that has finished its recipe but cannot get rid of the product.
func _is_output_full(entity: Entity, proto: Dictionary) -> bool:
	if entity.proto_type not in ["assembling-machine", "furnace"]:
		return false
	var output := InventoryLayout.get_inventory(entity, InventoryLayout.OUTPUT)
	if output == null or output.is_empty():
		return false
	# Full means no empty slot and no room left in the existing stacks.
	for slot: Variant in output.slots:
		if slot == null:
			return false
		if int(slot["count"]) < Prototypes.stack_size(str(slot["name"])):
			return false
	return true


## The danger icon, raised where the biters actually are.
func _enemy_alerts(sim: Simulation) -> Array:
	var out: Array = []
	var engineer := sim.character
	for unit: Dictionary in sim.units:
		var position := Vector2(unit["position"])
		if engineer != null and engineer.is_alive() \
				and position.distance_to(engineer.position) > DANGER_RANGE:
			continue
		out.append({
			"kind": ENEMIES,
			"cell": Vector2i(int(floor(position.x)), int(floor(position.y))),
			"entity": null,
			"message": "%s is attacking" % Loc.proto_name("unit",
				str(unit.get("name", ""))),
		})
	return out


# --------------------------------------------------------------------------
# queries for the panel
# --------------------------------------------------------------------------

## ``[{ kind, count, first_cell, first_message }]``, worst first.
func grouped() -> Array:
	var by_kind: Dictionary = {}
	for entry: Dictionary in items:
		var kind := str(entry["kind"])
		if not by_kind.has(kind):
			by_kind[kind] = {"kind": kind, "count": 0,
				"first_cell": entry["cell"], "first_message": entry["message"]}
		by_kind[kind]["count"] = int(by_kind[kind]["count"]) + 1
	var out: Array = []
	for kind: String in ORDER:
		if by_kind.has(kind):
			out.append(by_kind[kind])
	for kind: String in by_kind:
		if not ORDER.has(kind):
			out.append(by_kind[kind])
	return out


func count_of(kind: String) -> int:
	var total := 0
	for entry: Dictionary in items:
		if str(entry["kind"]) == kind:
			total += 1
	return total


func total() -> int:
	return items.size()


func clear() -> void:
	items.clear()
	_wrecks.clear()
