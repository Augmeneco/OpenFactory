class_name Objectives
extends RefCounted
## The chain of things to do, from the first lump of ore to the rocket.
##
## Factorio guides a new engineer with a list of objectives that light up as
## they are met, and sounds its `new_objective` cue when one falls.  This is
## that list: an ordered chain where every goal is a *check on the world*
## rather than a flag somebody has to remember to set, so an objective cannot
## claim to be done when it is not, and a player who skips ahead is simply
## further down the list than expected.

## One goal: what it says, and how to tell whether it is met.
##
## The check is called with the game's own state, so an objective can look at
## the inventory, the world, the research tree or the launch count.
var steps: Array = []
## Index of the first goal that is not yet met.
var current := 0

var player: Player
var world: GameWorld
var simulation: Simulation
var research: Research

## The last goal that was met, for the game to announce.
signal completed(index: int, title: String)
## Everything is done.
signal finished()


func _init(player_: Player, world_: GameWorld, simulation_: Simulation,
		research_: Research) -> void:
	player = player_
	world = world_
	simulation = simulation_
	research = research_
	_build()


func _build() -> void:
	steps = [
		{"title": "Mine some iron ore by hand",
			"detail": "Hold the right mouse button on an ore patch.",
			"check": func() -> bool: return _has("iron-ore", 1)},
		{"title": "Craft a stone furnace",
			"detail": "Open the inventory and craft it from stone.",
			"check": func() -> bool: return _has("stone-furnace", 1)},
		{"title": "Place the furnace",
			"detail": "Put it down and feed it ore and coal.",
			"check": func() -> bool: return _built("furnace")},
		{"title": "Smelt an iron plate",
			"detail": "The furnace turns ore into plates once it has fuel.",
			"check": func() -> bool: return _has("iron-plate", 1)},
		{"title": "Mine some coal",
			"detail": "Burner machines run on it.",
			"check": func() -> bool: return _has("coal", 1)},
		{"title": "Build a burner mining drill",
			"detail": "It digs ore out of the ground for you.",
			"check": func() -> bool: return _built("mining-drill")},
		{"title": "Build a transport belt",
			"detail": "Belts carry items between machines.",
			"check": func() -> bool: return _built("transport-belt")},
		{"title": "Run a belt to a machine",
			"detail": "A belt that ends at a furnace or a chest is a factory.",
			"check": func() -> bool: return _belts_and_machines()},
		{"title": "Research automation",
			"detail": "Put science packs in a lab and pick a technology.",
			"check": func() -> bool: return _researched("automation")},
		{"title": "Build an assembling machine",
			"detail": "Automation unlocks it.",
			"check": func() -> bool: return _built("assembling-machine")},
		{"title": "Build a lab",
			"detail": "Labs turn science packs into research.",
			"check": func() -> bool: return _built("lab")},
		{"title": "Get power flowing",
			"detail": "A boiler, a steam engine and a pole light up electric machines.",
			"check": func() -> bool: return _has_power()},
		{"title": "Build a rocket silo",
			"detail": "The end of the game is a rocket.",
			"check": func() -> bool: return _built("rocket-silo")},
		{"title": "Launch a rocket",
			"detail": "Fifty rocket parts and it is ready.",
			"check": func() -> bool: return _launched()},
	]


func _has(item_name: String, amount: int) -> bool:
	return player != null and player.inventory.count_of(item_name) >= amount


func _built(proto_type: String) -> bool:
	if world == null:
		return false
	# A ghost is a plan, not a machine, so only built ones count.
	for entity: Entity in world.entities_of_type(proto_type):
		if not entity.is_ghost():
			return true
	return false


func _researched(technology: String) -> bool:
	return research != null and research.is_researched(technology)


## A belt touching a machine: that is a factory rather than a pile of parts.
func _belts_and_machines() -> bool:
	if world == null:
		return false
	var belts := world.entities_of_type("transport-belt")
	if belts.is_empty():
		return false
	for belt: Entity in belts:
		for neighbour: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
				Vector2i(0, 1), Vector2i(0, -1)]:
			var other := world.entity_at(belt.origin + neighbour)
			if other == null or other.is_ghost():
				continue
			if other.proto_type in ["furnace", "assembling-machine", "container",
					"logistic-container", "mining-drill"]:
				return true
	return false


func _launched() -> bool:
	return simulation != null and simulation.rockets_launched > 0


func _has_power() -> bool:
	return simulation != null and simulation.power != null \
		and simulation.power.stats()["networks"] > 0 \
		and float(simulation.power.stats()["generation"]) > 0.0


# --------------------------------------------------------------------------
# progress
# --------------------------------------------------------------------------

## Work through the chain, announcing every goal that has been met since the
## last look.  Called once a second, which is often enough for a hint.
func update() -> void:
	if steps.is_empty():
		return
	while current < steps.size():
		var step: Dictionary = steps[current]
		var check: Callable = step["check"]
		if not bool(check.call()):
			break
		var met := current
		current += 1
		completed.emit(met, str(step["title"]))
	if current >= steps.size():
		finished.emit()


## The goal to show the player, or an empty dictionary when all are done.
func current_step() -> Dictionary:
	if current >= steps.size():
		return {}
	return steps[current]


func title_of(index: int) -> String:
	if index < 0 or index >= steps.size():
		return ""
	return str(steps[index]["title"])


func detail_of(index: int) -> String:
	if index < 0 or index >= steps.size():
		return ""
	return str(steps[index]["detail"])


func is_done(index: int) -> bool:
	return index < current


func total() -> int:
	return steps.size()


func progress() -> float:
	return float(current) / float(maxi(1, steps.size()))


func stats() -> Dictionary:
	return {"current": current, "total": steps.size(),
		"title": title_of(current), "done": current >= steps.size()}
