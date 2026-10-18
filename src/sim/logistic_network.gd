class_name LogisticNetwork
extends RefCounted
## Logistic robots, roboports and the five logistic chests.
##
## A roboport covers a circle; every logistic chest inside it joins that
## roboport's network.  Within a network the chests advertise what they hold
## and what they want, and the roboports dispatch robots to move the difference
## — one robot, one errand, flying in a straight line at its prototype's speed
## and paying for every tile out of its own battery.
##
## Overlapping roboports form one network, which is why Factorio bases join
## their robot coverage up instead of keeping separate pools.

## Chest modes, in the order robots prefer to take from them.
const MODE_PASSIVE := "passive-provider"
const MODE_ACTIVE := "active-provider"
const MODE_STORAGE := "storage"
const MODE_BUFFER := "buffer"
const MODE_REQUESTER := "requester"

## Where a robot can be taken from, best first.
const SOURCE_ORDER := [MODE_ACTIVE, MODE_BUFFER, MODE_STORAGE, MODE_PASSIVE]

## A construction robot finished a machine the player had only planned.
signal built_by_robot(entity: Entity)

## The engineer, for the personal roboport to work from.  Set by the game.
var player: Player

var world: GameWorld
## Every logistic robot in the world.
var robots: Array = []
## Construction robots, which have their own list because they answer to
## ghosts rather than to chests.
var builders: Array = []
var _dirty := true

var _networks: Array = []


func _init(world_: GameWorld) -> void:
	world = world_


func mark_dirty() -> void:
	_dirty = true


func stats() -> Dictionary:
	var idle := 0
	var working := 0
	var charging := 0
	for robot: Dictionary in robots:
		match str(robot.get("state", "")):
			"idle": idle += 1
			"charge": charging += 1
			_: working += 1
	return {
		"robots": robots.size(), "idle": idle, "working": working,
		"charging": charging,
		"builders": builders.size(),
		"built": _built,
		"delivered": _delivered,
		"networks": _networks.size(),
	}


var _delivered := 0
var _built := 0


# --------------------------------------------------------------------------
# networks
# --------------------------------------------------------------------------

static func mode_of(chest: Entity) -> String:
	return str(chest.prototype().get("logistic_mode", ""))


static func is_logistic_chest(entity: Entity) -> bool:
	return not mode_of(entity).is_empty()


## Radius of a roboport's logistic coverage.
static func logistics_radius(roboport: Entity) -> float:
	return float(roboport.prototype().get("logistics_radius", 25.0))


static func construction_radius(roboport: Entity) -> float:
	return float(roboport.prototype().get("construction_radius", 55.0))


## Rebuild the network list: roboports whose coverage overlaps are merged.
func rebuild() -> void:
	_dirty = false
	_networks.clear()
	var ports: Array = world.entities_of_type("roboport")
	if ports.is_empty():
		return

	var parent: Dictionary = {}
	for port: Entity in ports:
		parent[port.origin] = port.origin

	for i in ports.size():
		for j in range(i + 1, ports.size()):
			var a: Entity = ports[i]
			var b: Entity = ports[j]
			var reach := logistics_radius(a) + logistics_radius(b)
			if a.center().distance_to(b.center()) <= reach:
				_union(parent, a.origin, b.origin)

	var groups: Dictionary = {}
	for port: Entity in ports:
		var root: Vector2i = _find(parent, port.origin)
		if not groups.has(root):
			groups[root] = []
		(groups[root] as Array).append(port)

	for root: Vector2i in groups:
		var members: Array = groups[root]
		var chests: Array = []
		var seen: Dictionary = {}
		for port: Entity in members:
			var radius := logistics_radius(port)
			for entity: Entity in world.entities.values():
				if entity.is_ghost():
					continue
				if not is_logistic_chest(entity):
					continue
				if seen.has(entity.origin):
					continue
				if port.center().distance_to(entity.center()) <= radius:
					seen[entity.origin] = true
					chests.append(entity)
		_networks.append({"ports": members, "chests": chests})


func _find(parent: Dictionary, key: Vector2i) -> Vector2i:
	var root := key
	while parent[root] != root:
		root = parent[root]
	var walk := key
	while parent[walk] != root:
		var next: Vector2i = parent[walk]
		parent[walk] = root
		walk = next
	return root


func _union(parent: Dictionary, a: Vector2i, b: Vector2i) -> void:
	var root_a := _find(parent, a)
	var root_b := _find(parent, b)
	if root_a != root_b:
		parent[root_b] = root_a


## The network a roboport is part of, or an empty dictionary.
func network_of(port: Entity) -> Dictionary:
	if _dirty:
		rebuild()
	for network: Dictionary in _networks:
		if (network["ports"] as Array).has(port):
			return network
	return {}


## The network covering a point, or an empty dictionary.
func network_at(cell: Vector2i) -> Dictionary:
	if _dirty:
		rebuild()
	for network: Dictionary in _networks:
		for port: Entity in network["ports"]:
			if port.center().distance_to(Vector2(cell) + Vector2(0.5, 0.5)) \
					<= logistics_radius(port):
				return network
	return {}


# --------------------------------------------------------------------------
# requests and offers
# --------------------------------------------------------------------------

## What a chest wants: ``{ item: count }``.  Only requester and buffer chests
## ask for anything, and a buffer chest also serves item requests itself.
static func requests_of(chest: Entity) -> Dictionary:
	var mode := mode_of(chest)
	if mode != MODE_REQUESTER and mode != MODE_BUFFER:
		return {}
	var raw: Variant = chest.state.get("requests", {})
	return raw if raw is Dictionary else {}


## Whether a chest will hand items over, and how willingly.
static func source_rank(chest: Entity) -> int:
	var mode := mode_of(chest)
	var index := SOURCE_ORDER.find(mode)
	return index if index >= 0 else -1


static func storage_of(chest: Entity) -> Inventory:
	return InventoryLayout.get_inventory(chest, InventoryLayout.STORAGE)


# --------------------------------------------------------------------------
# robots
# --------------------------------------------------------------------------

static func robot_prototype() -> Dictionary:
	return Prototypes.get_p("logistic-robot", "logistic-robot")


## The robot prototype, and the modifier set if the caller has one.
var modifiers: Modifiers


static func payload_size() -> int:
	var proto := robot_prototype()
	# ``max_payload_size`` counts stacks, which is what the worker-robot-storage
	# research adds to one at a time.
	return maxi(1, int(proto.get("max_payload_size", 1)))


## Item units a robot carries, once research is counted.
func payload_for(item_name: String) -> int:
	if modifiers != null:
		return modifiers.robot_payload(item_name)
	return payload_size() * Prototypes.stack_size(item_name)


## Robots belonging to a roboport: parked ones plus those out on errands.
func robots_of(port: Entity) -> Array:
	var out: Array = []
	for robot: Dictionary in robots:
		if robot.get("home") == port:
			out.append(robot)
	return out


## Find a robot that can take an errand, creating one if the roboport still has
## a free slot.
func _free_robot(port: Entity) -> Dictionary:
	for robot: Dictionary in robots_of(port):
		if str(robot.get("state", "")) == "idle":
			return robot
	var limit := int(port.prototype().get("robot_slots_count", 7))
	var owned := robots_of(port)
	if owned.size() >= limit:
		return {}
	var proto := robot_prototype()
	var robot := {
		"name": "logistic-robot",
		"position": port.center() + Vector2(0, -0.5),
		"direction": 8,
		"energy": Energy.parse(proto.get("max_energy"), 1500000.0),
		"max_energy": Energy.parse(proto.get("max_energy"), 1500000.0),
		"state": "idle",
		"home": port,
		"task": {},
		"carrying": {},
		"animation": 0.0,
	}
	robots.append(robot)
	return robot


func _assign(robot: Dictionary, pickup: Entity, dropoff: Entity, item: String,
		count: int) -> void:
	robot["state"] = "pickup"
	robot["task"] = {
		"pickup": pickup.origin, "dropoff": dropoff.origin,
		"item": item, "count": count,
	}
	robot["carrying"] = {}


# --------------------------------------------------------------------------
# tick
# --------------------------------------------------------------------------

func update() -> void:
	if _dirty:
		rebuild()
	# A personal roboport needs no network at all, so an empty world with one
	# worn must not skip the tick — and robots still in the air after the suit
	# comes off must keep flying so they can come home.
	if _networks.is_empty() and robots.is_empty() and builders.is_empty() \
			and not _has_personal_roboport():
		return
	_dispatch()
	_dispatch_builders()
	_dispatch_personal()
	_fly()
	_fly_builders()


## Match what the chests want against what they hold, and send robots.
func _dispatch() -> void:
	# What is already on its way counts against the request, or seven robots
	# would all answer the same one and bury the chest.
	var in_flight: Dictionary = {}
	for robot: Dictionary in robots:
		var task: Dictionary = robot.get("task", {})
		if task.is_empty():
			continue
		var key := "%s|%s" % [str(task.get("dropoff", Vector2i.ZERO)),
			str(task.get("item", ""))]
		in_flight[key] = int(in_flight.get(key, 0)) + int(task.get("count", 0))

	for network: Dictionary in _networks:
		var requests: Array = []
		var offers: Dictionary = {}
		for chest: Entity in network["chests"]:
			var storage := storage_of(chest)
			if storage == null:
				continue
			var wanted := requests_of(chest)
			for item: String in wanted:
				var have := storage.count_of(item)
				var coming := int(in_flight.get("%s|%s" % [str(chest.origin), item], 0))
				var want := int(wanted[item])
				if want > have + coming:
					requests.append({"chest": chest, "item": item,
						"count": want - have - coming})
			var rank := source_rank(chest)
			if rank < 0:
				continue
			for slot: Variant in storage.slots:
				if slot == null:
					continue
				var name := str(slot.get("name", ""))
				if not offers.has(name):
					offers[name] = []
				(offers[name] as Array).append({"chest": chest, "rank": rank})

		for request: Dictionary in requests:
			var item := str(request["item"])
			if not offers.has(item):
				continue
			var ports: Array = network["ports"]
			var robot := _pick_robot(ports, request["chest"] as Entity)
			if robot.is_empty():
				continue
			var source: Variant = _pick_source(offers[item],
				request["chest"] as Entity, item)
			if source == null:
				continue
			var payload := payload_for(item)
			var count: int = mini(int(request["count"]), payload)
			_assign(robot, source as Entity, request["chest"] as Entity, item, count)


## The roboport closest to the errand has a robot to spare.
func _pick_robot(ports: Array, near: Entity) -> Dictionary:
	var ordered: Array = ports.duplicate()
	ordered.sort_custom(func(a: Entity, b: Entity) -> bool:
		return a.center().distance_to(near.center()) \
			< b.center().distance_to(near.center()))
	for port: Entity in ordered:
		var robot := _free_robot(port)
		if not robot.is_empty():
			return robot
	return {}


## The best chest to take an item from.
##
## Rank dominates — an active provider before a storage chest before a passive
## one — and distance decides inside a rank.  Chests that have been emptied
## since the offers were collected are skipped.
func _pick_source(candidates: Array, near: Entity, item: String) -> Variant:
	var best: Variant = null
	var best_key := 1e18
	for entry: Dictionary in candidates:
		var chest: Entity = entry["chest"]
		var storage := storage_of(chest)
		if storage == null or storage.count_of(item) <= 0:
			continue
		var key := float(int(entry["rank"])) * 100000.0 \
			+ chest.center().distance_to(near.center())
		if key < best_key:
			best_key = key
			best = chest
	return best


# --------------------------------------------------------------------------
# construction
# --------------------------------------------------------------------------

static func builder_prototype() -> Dictionary:
	return Prototypes.get_p("construction-robot", "construction-robot")


## Every ghost a roboport's construction area covers.
func _ghosts_for(port: Entity) -> Array:
	var out: Array = []
	var radius := construction_radius(port)
	for entity: Entity in world.entities.values():
		if not entity.is_ghost():
			continue
		if port.center().distance_to(entity.center()) <= radius:
			out.append(entity)
	return out


func builders_of(port: Entity) -> Array:
	var out: Array = []
	for robot: Dictionary in builders:
		if robot.get("home") == port:
			out.append(robot)
	return out


## A free construction robot at this roboport, or a new one if there is a slot.
func _free_builder(port: Entity) -> Dictionary:
	for robot: Dictionary in builders_of(port):
		if str(robot.get("state", "")) == "idle":
			return robot
	var limit := int(port.prototype().get("robot_slots_count", 7))
	if builders_of(port).size() >= limit:
		return {}
	var proto := builder_prototype()
	var robot := {
		"name": "construction-robot",
		"position": port.center() + Vector2(0, -0.5),
		"direction": 8,
		"energy": Energy.parse(proto.get("max_energy"), 3000000.0),
		"max_energy": Energy.parse(proto.get("max_energy"), 3000000.0),
		"state": "idle",
		"home": port,
		"task": {},
		"animation": 0.0,
	}
	builders.append(robot)
	return robot


## Send a robot at every ghost that has not been claimed yet.
##
## Factorio keeps a ghost queue and hands jobs out to whatever robot is free;
## the same shape works here — a ghost with a robot already heading for it is
## skipped, so two robots never race for one plan.
func _dispatch_builders() -> void:
	if _networks.is_empty():
		return
	var claimed: Dictionary = {}
	for robot: Dictionary in builders:
		var task: Dictionary = robot.get("task", {})
		if task.has("ghost"):
			claimed[str(task["ghost"])] = true

	for network: Dictionary in _networks:
		for port: Entity in network["ports"]:
			for ghost: Entity in _ghosts_for(port):
				if claimed.has(str(ghost.origin)):
					continue
				var robot := _free_builder(port)
				if robot.is_empty():
					continue
				robot["state"] = "ghost"
				robot["task"] = {"ghost": ghost.origin, "home": port.origin}
				claimed[str(ghost.origin)] = true


## What one machine of a ghost would cost, as a list of ``{ name, amount }``.
static func _ghost_costs(ghost: Entity) -> Array:
	return Blueprints.costs_of(str(ghost.state.get("ghost_of", ghost.proto_type)),
		ghost.name)


## Take the ingredients for a ghost out of the network's own chests.
##
## Factorio's construction robots take from the logistic network, not from the
## player, so the chests are searched the way a requester's request would be.
func _withdraw(port: Entity, costs: Array) -> bool:
	if costs.is_empty():
		return true
	var network := network_of(port)
	for cost: Dictionary in costs:
		var wanted := int(cost["amount"])
		var item := str(cost["name"])
		for chest: Entity in network.get("chests", []):
			if wanted <= 0:
				break
			if source_rank(chest) < 0:
				continue
			var storage := storage_of(chest)
			if storage == null:
				continue
			var taken := storage.extract(item, wanted)
			wanted -= taken
		if wanted > 0:
			# Put back what was taken; the job waits for the rest.
			var shortfall := int(cost["amount"]) - wanted
			for chest: Entity in network.get("chests", []):
				if shortfall <= 0:
					break
				if source_rank(chest) < 0:
					continue
				var storage := storage_of(chest)
				if storage == null:
					continue
				shortfall -= storage.insert(item, shortfall)
			return false
	return true


## Fly the construction robots, and build what they arrive at.
func _fly_builders() -> void:
	var proto := builder_prototype()
	var speed := float(proto.get("speed", 0.06))
	if modifiers != null:
		speed *= modifiers.robot_speed_multiplier()
	var per_move := Energy.parse(proto.get("energy_per_move"), 5000.0)
	var per_tick := Energy.parse(proto.get("energy_per_tick"), 50.0)
	var max_energy := Energy.parse(proto.get("max_energy"), 3000000.0)
	var charge_rate := Energy.parse(
		Prototypes.get_p("roboport", "roboport").get("charging_energy"), 500000.0)

	for robot: Dictionary in builders:
		robot["energy"] = maxf(0.0, float(robot["energy"]) - per_tick)
		var state := str(robot.get("state", "idle"))
		var position := Vector2(robot["position"])
		var target := _builder_target(robot)
		var distance := position.distance_to(target)

		if state == "charge":
			if bool(robot.get("personal", false)):
				robot["energy"] = minf(max_energy,
					float(robot["energy"]) + charge_rate / 60.0)
				if float(robot["energy"]) >= max_energy * 0.95:
					robot["state"] = "idle"
				continue
			var port: Variant = robot.get("home")
			if port is Entity and world.entities.has((port as Entity).origin):
				robot["energy"] = minf(max_energy,
					float(robot["energy"]) + charge_rate / 60.0)
				if float(robot["energy"]) >= max_energy * 0.95:
					robot["state"] = "idle"
			continue

		if distance <= speed:
			robot["position"] = target
			_arrive_builder(robot)
			continue

		var step := (target - position).normalized() * speed
		robot["position"] = position + step
		robot["direction"] = Simulation._direction_from_vector(step)
		robot["animation"] = float(robot.get("animation", 0.0)) + 1.0
		robot["energy"] = maxf(0.0, float(robot["energy"]) - per_move * speed)
		if float(robot["energy"]) <= max_energy * 0.2:
			robot["state"] = "charge"
			robot["task"] = {}


func _builder_target(robot: Dictionary) -> Vector2:
	var state := str(robot.get("state", "idle"))
	var task: Dictionary = robot.get("task", {})
	if state == "ghost":
		var ghost: Variant = task.get("ghost", null)
		if ghost is Vector2i:
			var entity := world.entity_at(ghost as Vector2i)
			if entity != null:
				return entity.center()
	return _home_position(robot)


## A construction robot arrived at its ghost.  If the network can pay for the
## machine it goes up; if not, the robot goes home and the ghost waits.
## Whether the engineer is wearing a personal roboport.
func _has_personal_roboport() -> bool:
	if player == null or player.character == null:
		return false
	return float(player.character.equipment.effects()["construction_radius"]) > 0.0


## Launch construction robots from a personal roboport.
##
## The engineer's own robots answer to the engineer: they take their materials
## out of the inventory being carried, not out of a chest, and they fly home to
## the engineer rather than to a roboport.  That is the whole difference, so the
## rest of the flight is shared with the ported robots.
func _dispatch_personal() -> void:
	if player == null or player.character == null:
		return
	var effects := player.character.equipment.effects()
	var radius := float(effects["construction_radius"])
	var limit := int(effects["robot_limit"])
	var mine: Array = []
	for robot: Dictionary in builders:
		if bool(robot.get("personal", false)):
			mine.append(robot)
	if radius <= 0.0 or limit <= 0:
		# The suit came off, so the robots still in the air are recalled.
		for robot: Dictionary in mine:
			if str(robot.get("state", "")) == "idle":
				builders.erase(robot)
		return

	var claimed: Dictionary = {}
	for robot: Dictionary in mine:
		var task: Dictionary = robot.get("task", {})
		if task.has("ghost"):
			claimed[str(task["ghost"])] = true

	var centre := player.character.position
	for entity: Entity in world.entities.values():
		if not entity.is_ghost():
			continue
		if centre.distance_to(entity.center()) > radius:
			continue
		if claimed.has(str(entity.origin)):
			continue
		var robot := _free_personal_builder(limit)
		if robot.is_empty():
			return
		robot["state"] = "ghost"
		robot["task"] = {"ghost": entity.origin}
		claimed[str(entity.origin)] = true


## A free robot of the engineer's, or a new one if the suit allows another.
func _free_personal_builder(limit: int) -> Dictionary:
	var mine: Array = []
	for robot: Dictionary in builders:
		if bool(robot.get("personal", false)):
			mine.append(robot)
	for robot: Dictionary in mine:
		if str(robot.get("state", "")) == "idle":
			return robot
	if mine.size() >= limit:
		return {}
	var proto := builder_prototype()
	var position := player.character.position if player != null \
		and player.character != null else Vector2.ZERO
	var robot := {
		"name": "construction-robot",
		"position": position,
		"direction": 8,
		"energy": Energy.parse(proto.get("max_energy"), 3000000.0),
		"max_energy": Energy.parse(proto.get("max_energy"), 3000000.0),
		"state": "idle",
		"home": null,
		"personal": true,
		"task": {},
		"animation": 0.0,
	}
	builders.append(robot)
	return robot


## Take the ingredients for a ghost out of the engineer's own inventory.
func _withdraw_personal(costs: Array) -> bool:
	if costs.is_empty():
		return true
	if player == null:
		return false
	for cost: Dictionary in costs:
		if not player.inventory.has_at_least([cost]):
			return false
	for cost: Dictionary in costs:
		player.inventory.extract(str(cost["name"]), int(cost["amount"]))
	player.inventory_changed.emit()
	return true


func _arrive_builder(robot: Dictionary) -> void:
	var task: Dictionary = robot.get("task", {})
	var ghost_cell: Variant = task.get("ghost", null)
	if not (ghost_cell is Vector2i):
		robot["state"] = "idle"
		robot["task"] = {}
		return
	var ghost := world.entity_at(ghost_cell as Vector2i)
	if ghost == null or not ghost.is_ghost():
		# Somebody built it, or took the plan away.
		robot["state"] = "idle"
		robot["task"] = {}
		return
	if bool(robot.get("personal", false)):
		if not _withdraw_personal(_ghost_costs(ghost)):
			robot["state"] = "idle"
			robot["task"] = {}
			return
	else:
		var port: Variant = robot.get("home")
		if not (port is Entity) or not world.entities.has((port as Entity).origin):
			robot["state"] = "idle"
			robot["task"] = {}
			return
		if not _withdraw(port as Entity, _ghost_costs(ghost)):
			robot["state"] = "idle"
			robot["task"] = {}
			return
	var real := world.revive_ghost(ghost)
	robot["state"] = "idle"
	robot["task"] = {}
	if real != null:
		_built += 1
		built_by_robot.emit(real)


## Fly every robot towards whatever it is doing, and pay for the trip.
func _fly() -> void:
	var proto := robot_prototype()
	var speed := float(proto.get("speed", 0.05))
	if modifiers != null:
		speed *= modifiers.robot_speed_multiplier()
	var per_move := Energy.parse(proto.get("energy_per_move"), 5000.0)
	var per_tick := Energy.parse(proto.get("energy_per_tick"), 50.0)
	var max_energy := Energy.parse(proto.get("max_energy"), 1500000.0)
	var charge_rate := Energy.parse(
		Prototypes.get_p("roboport", "roboport").get("charging_energy"), 500000.0)

	for robot: Dictionary in robots:
		robot["energy"] = maxf(0.0, float(robot["energy"]) - per_tick)
		var state := str(robot.get("state", "idle"))
		var position := Vector2(robot["position"])
		var target := _target_of(robot)
		var distance := position.distance_to(target)

		if state == "charge":
			if bool(robot.get("personal", false)):
				robot["energy"] = minf(max_energy,
					float(robot["energy"]) + charge_rate / 60.0)
				if float(robot["energy"]) >= max_energy * 0.95:
					robot["state"] = "idle"
				continue
			var port: Variant = robot.get("home")
			if port is Entity and world.entities.has((port as Entity).origin):
				robot["energy"] = minf(max_energy,
					float(robot["energy"]) + charge_rate / 60.0)
				if float(robot["energy"]) >= max_energy * 0.95:
					robot["state"] = "idle"
			continue

		if distance <= speed:
			robot["position"] = target
			_arrive(robot)
			continue

		var step := (target - position).normalized() * speed
		robot["position"] = position + step
		robot["direction"] = Simulation._direction_from_vector(step)
		robot["animation"] = float(robot.get("animation", 0.0)) + 1.0
		robot["energy"] = maxf(0.0, float(robot["energy"]) - per_move * speed)

		# Out of charge: drop the errand and go home.
		if float(robot["energy"]) <= max_energy * 0.2:
			robot["state"] = "charge"
			robot["task"] = {}
			robot["carrying"] = {}




func _target_of(robot: Dictionary) -> Vector2:
	var state := str(robot.get("state", "idle"))
	var task: Dictionary = robot.get("task", {})
	match state:
		"pickup":
			var pickup := _entity_at(task.get("pickup", Vector2i.ZERO))
			return pickup.center() if pickup != null else _home_position(robot)
		"dropoff":
			var dropoff := _entity_at(task.get("dropoff", Vector2i.ZERO))
			return dropoff.center() if dropoff != null else _home_position(robot)
		"charge":
			return _home_position(robot)
		_:
			return _home_position(robot)


func _home_position(robot: Dictionary) -> Vector2:
	if bool(robot.get("personal", false)):
		return player.character.position if player != null \
			and player.character != null else Vector2(robot["position"])
	var port: Variant = robot.get("home")
	if port is Entity and world.entities.has((port as Entity).origin):
		return (port as Entity).center()
	return Vector2(robot["position"])


func _entity_at(origin: Variant) -> Entity:
	if not (origin is Vector2i):
		return null
	return world.entity_at(origin as Vector2i)


## A robot reached whatever it was flying to.
func _arrive(robot: Dictionary) -> void:
	var state := str(robot.get("state", "idle"))
	var task: Dictionary = robot.get("task", {})
	match state:
		"pickup":
			var source := _entity_at(task.get("pickup", Vector2i.ZERO))
			var storage := storage_of(source) if source != null else null
			if storage == null:
				_abandon(robot)
				return
			var item := str(task.get("item", ""))
			var carried: int = mini(int(task.get("count", 0)),
				storage.count_of(item))
			if carried <= 0:
				_abandon(robot)
				return
			storage.extract(item, carried)
			robot["carrying"] = {"name": item, "count": carried}
			robot["state"] = "dropoff"
		"dropoff":
			var target := _entity_at(task.get("dropoff", Vector2i.ZERO))
			var into := storage_of(target) if target != null else null
			var cargo: Dictionary = robot.get("carrying", {})
			if into == null or cargo.is_empty():
				_abandon(robot)
				return
			# ``insert`` returns what did NOT fit, not what went in.
			var carried := int(cargo["count"])
			var leftover := into.insert(str(cargo["name"]), carried)
			_delivered += carried - leftover
			# Whatever did not fit goes back to the source rather than
			# vanishing.
			if leftover > 0:
				var source := _entity_at(task.get("pickup", Vector2i.ZERO))
				var back := storage_of(source) if source != null else null
				if back != null:
					back.insert(str(cargo["name"]), leftover)
			robot["carrying"] = {}
			robot["state"] = "idle"
			robot["task"] = {}
		_:
			robot["state"] = "idle"


func _abandon(robot: Dictionary) -> void:
	# Put anything still in the arms back where it came from.
	var cargo: Dictionary = robot.get("carrying", {})
	if not cargo.is_empty():
		var source := _entity_at((robot.get("task", {}) as Dictionary).get(
			"pickup", Vector2i.ZERO))
		var back := storage_of(source) if source != null else null
		if back != null:
			back.insert(str(cargo["name"]), int(cargo["count"]))
	robot["carrying"] = {}
	robot["task"] = {}
	robot["state"] = "idle"


func clear() -> void:
	robots.clear()
	builders.clear()


# --------------------------------------------------------------------------
# serialisation
# --------------------------------------------------------------------------

func to_dict() -> Dictionary:
	var out: Array = []
	for robot: Dictionary in robots:
		var home: Variant = robot.get("home")
		var task: Dictionary = robot.get("task", {})
		out.append({
			"position": [Vector2(robot["position"]).x, Vector2(robot["position"]).y],
			"direction": int(robot.get("direction", 8)),
			"energy": float(robot.get("energy", 0.0)),
			"state": str(robot.get("state", "idle")),
			"carrying": robot.get("carrying", {}),
			"home": [home.origin.x, home.origin.y] if home is Entity else null,
			"personal": bool(robot.get("personal", false)),
			"task": {
				"pickup": _origin_list(task.get("pickup")),
				"dropoff": _origin_list(task.get("dropoff")),
				"item": str(task.get("item", "")),
				"count": int(task.get("count", 0)),
			} if not task.is_empty() else {},
			"animation": float(robot.get("animation", 0.0)),
		})
	return {"robots": out, "delivered": _delivered, "built": _built,
		"builders": _builders_to_dict()}


static func _origin_list(value: Variant) -> Variant:
	if value is Vector2i:
		return [(value as Vector2i).x, (value as Vector2i).y]
	return null


func _builders_to_dict() -> Array:
	var out: Array = []
	for robot: Dictionary in builders:
		var home: Variant = robot.get("home")
		var task: Dictionary = robot.get("task", {})
		out.append({
			"position": [Vector2(robot["position"]).x, Vector2(robot["position"]).y],
			"direction": int(robot.get("direction", 8)),
			"energy": float(robot.get("energy", 0.0)),
			"state": str(robot.get("state", "idle")),
			"animation": float(robot.get("animation", 0.0)),
			"home": [home.origin.x, home.origin.y] if home is Entity else null,
			"personal": bool(robot.get("personal", false)),
			"ghost": _origin_list(task.get("ghost")),
		})
	return out


func from_dict(data: Dictionary) -> void:
	clear()
	_delivered = int(data.get("delivered", 0))
	_built = int(data.get("built", 0))
	for entry: Variant in data.get("builders", []):
		if not (entry is Dictionary):
			continue
		var values: Array = entry.get("position", [0.0, 0.0])
		var robot := {
			"name": "construction-robot",
			"position": Vector2(float(values[0]), float(values[1])),
			"direction": int(entry.get("direction", 8)),
			"energy": float(entry.get("energy", 0.0)),
			"max_energy": Energy.parse(builder_prototype().get("max_energy"),
				3000000.0),
			"state": str(entry.get("state", "idle")),
			"home": _entity_at(_to_cell(entry.get("home"))),
			"personal": bool(entry.get("personal", false)),
			"task": {},
			"animation": float(entry.get("animation", 0.0)),
		}
		var ghost := _to_cell(entry.get("ghost"))
		if ghost != Vector2i.ZERO:
			robot["task"] = {"ghost": ghost}
		builders.append(robot)
	for entry: Variant in data.get("robots", []):
		if not (entry is Dictionary):
			continue
		var position_values: Array = entry.get("position", [0.0, 0.0])
		var record := {
			"name": "logistic-robot",
			"position": Vector2(float(position_values[0]), float(position_values[1])),
			"direction": int(entry.get("direction", 8)),
			"energy": float(entry.get("energy", 0.0)),
			"max_energy": Energy.parse(robot_prototype().get("max_energy"), 1500000.0),
			"state": str(entry.get("state", "idle")),
			"home": _entity_at(_to_cell(entry.get("home"))),
			"personal": bool(entry.get("personal", false)),
			"task": {},
			"carrying": entry.get("carrying", {}),
			"animation": float(entry.get("animation", 0.0)),
		}
		var task: Variant = entry.get("task", {})
		if task is Dictionary and not (task as Dictionary).is_empty():
			record["task"] = {
				"pickup": _to_cell(task.get("pickup")),
				"dropoff": _to_cell(task.get("dropoff")),
				"item": str(task.get("item", "")),
				"count": int(task.get("count", 0)),
			}
		robots.append(record)


static func _to_cell(value: Variant) -> Vector2i:
	if value is Array and (value as Array).size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO
