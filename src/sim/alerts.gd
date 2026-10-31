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

const DESTROYED := "destroyed"
const DAMAGED := "damaged"
const ENEMIES := "enemies"
const NO_BUILDING_MATERIAL := "no-building-material"

## The real icon each alert uses, straight out of ``__core__``.
const ICONS := {
	DESTROYED: "__core__/graphics/icons/alerts/destroyed-icon.png",
	DAMAGED: "__core__/graphics/icons/alerts/warning-icon.png",
	ENEMIES: "__core__/graphics/icons/alerts/danger-icon.png",
	NO_BUILDING_MATERIAL: "__core__/graphics/icons/alerts/no-building-material-icon.png",
}

## How the panel orders them: immediate danger first.
const ORDER := [ENEMIES, DAMAGED, DESTROYED, NO_BUILDING_MATERIAL]

const TITLES := {
	DESTROYED: "Destroyed",
	DAMAGED: "Damaged",
	ENEMIES: "Enemies nearby",
	NO_BUILDING_MATERIAL: "Drones lack materials",
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
	# The sidebar is for things the player must act on, not a status mirror of
	# every machine.  A missing power/fuel/ammo/output icon already appears on
	# the entity itself; only damage and dangerous logistics get a global row.
	for entity: Entity in world.entities.values():
		if entity.is_ghost():
			continue
		if _is_damaged(entity):
			var proto := entity.prototype()
			found.append(_entry(DAMAGED, entity,
				"%s is damaged" % Loc.proto_display_name(proto, entity.name)))
	# Ghosts that no roboport can reach, or whose materials are absent from
	# the network, are the construction-robot equivalent of a blocked machine.
	for entity: Entity in world.entities.values():
		if not entity.is_ghost():
			continue
		# No construction coverage means this ghost is simply not a robot job;
		# it must not generate a global alert.  Only a covered ghost whose
		# network cannot pay for it is a real logistics problem.
		var network := sim.logistics.construction_network_at(entity.origin)
		if network.is_empty():
			continue
		if not _network_can_pay(sim, network, entity):
			found.append({
				"kind": NO_BUILDING_MATERIAL, "cell": entity.origin,
				"entity": entity,
				"message": "Drones lack materials for %s" % entity.name,
			})

	for wreck: Dictionary in _wrecks:
		var name := Loc.proto_name("item", str(wreck["name"])) \
			if Prototypes.is_item(str(wreck["name"])) else str(wreck["name"])
		found.append({
			"kind": DESTROYED, "cell": wreck["cell"], "entity": null,
			"message": "%s was destroyed" % name,
		})

	found.append_array(_enemy_alerts(sim))
	return found


## Something the biters (or fire) have already damaged.  Trees and rocks are
## scenery and would flood the list after every forest fire.
static func _is_damaged(entity: Entity) -> bool:
	if entity.proto_type in ["tree", "simple-entity", "item-entity"]:
		return false
	var proto := entity.prototype()
	var flags: Variant = proto.get("flags", [])
	if flags is Array and not ((flags as Array).has("player-creation") \
			or (flags as Array).has("placeable-player")):
		return false
	var max_health: Variant = proto.get("max_health", null)
	if max_health == null or float(max_health) <= 0.0:
		return false
	var health: Variant = entity.state.get("health", null)
	if health == null:
		return false
	return float(health) < float(max_health) - 0.01


## Can the network's source chests pay for this ghost?
static func _network_can_pay(sim: Simulation, network: Dictionary,
		ghost: Entity) -> bool:
	var costs := LogisticNetwork._ghost_costs(ghost)
	if costs.is_empty():
		return true
	# Include the construction chests near the ghost, exactly like the robots
	# do; otherwise a buildable plan would still raise "drones lack materials".
	var chests: Array = []
	for port: Entity in network.get("ports", []):
		for chest: Entity in sim.logistics.builder_sources(port, ghost.origin,
				costs):
			if not chests.has(chest):
				chests.append(chest)
	return LogisticNetwork.chests_can_pay(chests, costs)


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
