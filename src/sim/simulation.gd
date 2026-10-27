class_name Simulation
extends RefCounted
## The factory tick loop.
##
## Factorio updates its world 60 times a second.  Everything here runs on that
## clock: belts advance items, inserters swing, drills bore into ore and
## furnaces smelt, all at the real speeds taken from the prototype data
## (belt 0.03125 tiles/tick, stone furnace crafting speed 1, and so on).

const TICKS_PER_SECOND := 60
const TICK_DELTA := 1.0 / 60.0

var world: GameWorld
var power: PowerNetwork
## Technology tree; labs feed it science packs.
var research: Research
## Pipes, tanks and machine fluid boxes.
var fluids: FluidSystem
## Pollution per chunk, and the smog that draws the biters.
var pollution: Pollution
## Roboports, logistic chests and the robots that run between them.
var logistics: LogisticNetwork
## What the alert panel shows.
var alerts: Alerts
## Rails and the trains that run on them.
var trains: Trains
## What the factory has made and eaten.
var statistics: Statistics
## Rockets launched, which is what finishes the game.
var rockets_launched := 0
## Set once the first rocket goes up, so the win screen only shows once.
var victory_announced := false
## Red and green wires and the signals on them.
var circuits: CircuitNetwork
## The time of day, and how dark it is.
var day: DayCycle
## Living enemies.  Biters walk off the tile grid, so they are not world
## entities (which are keyed by tile) but plain records with a float position.
var units: Array = []
## A hard ceiling on simultaneously simulated biters.  Spawners keep their own
## local caps, but a large explored biter region can otherwise accumulate
## thousands of off-screen units and tank the frame rate.
const MAX_ACTIVE_UNITS := 200
## The engineer, so biters can bite them and the game can respawn them.
var character: Character
## Evolution factor, 0..1, which decides what a nest is allowed to spawn.
var evolution := 0.0
## World-settings multiplier for how fast evolution grows.
var evolution_speed := 1.0
## New chunks inside this many chunks around the start do not receive nests.
var enemy_safe_chunks := 14
## Player start, in chunk coordinates; set once the engineer's spawn is known.
var enemy_safe_center := Vector2i.ZERO
var _elapsed_seconds := 0.0
var _pollution_produced := 0.0
var tick: int = 0
var paused := false

## Rolling counters for the debug overlay.
##
## These keys are never removed: `clear()` on this dictionary wipes the names
## as well as the values, and every reader that does `stats["mined"]` then
## throws.  Use `reset_stats()` instead.
var stats := {
	"belts": 0, "belt_items": 0, "inserters": 0, "crafts": 0,
	"mined": 0, "power_generation": 0.0, "power_demand": 0.0,
}

signal item_mined(cell: Vector2i, item_name: String, amount: int)
## A machine was destroyed — by biters, most likely.
signal entity_destroyed(entity: Entity, attacker: Variant)
## Items spilled out of a wreck, so the renderer can show them.
signal spilled(position: Vector2, item_name: String, amount: int)
## A turret hit something.
signal unit_hit(unit: Dictionary, amount: float)
## The alert list was rebuilt, so the panel should redraw.
signal alerts_changed
## A rocket left the pad; the game showed the win screen on the first one.
signal rocket_launched(number: int)


func _init(world_: GameWorld) -> void:
	world = world_
	power = PowerNetwork.new(world_)
	fluids = FluidSystem.new(world_)
	pollution = Pollution.new(world_)
	logistics = LogisticNetwork.new(world_)
	alerts = Alerts.new()
	trains = Trains.new(world_)
	statistics = Statistics.new()
	circuits = CircuitNetwork.new(world_)
	circuits.fluids = fluids
	day = DayCycle.new()
	entity_destroyed.connect(func(entity: Entity, _attacker: Variant) -> void:
		alerts.on_destroyed(entity))
	world.entity_placed.connect(_on_entity_changed)
	world.entity_removed.connect(_on_entity_changed)
	world.chunk_generated.connect(_on_chunk_generated)


## Placement feeds the "build-entity" trigger technologies and invalidates the
## pipe and power topology.
func _on_entity_changed(entity: Entity) -> void:
	if research != null:
		research.on_entity_built(entity.name)
	fluids.mark_dirty()
	power.mark_dirty()
	logistics.mark_dirty()


## Entities of a type that are actually built.  Ghosts are plans, so nothing
## simulates them — only the construction robots care.
func live_of_type(proto_type: String) -> Array:
	var out: Array = []
	for entity: Entity in world.entities_of_type(proto_type):
		if not entity.is_ghost():
			out.append(entity)
	return out


## Put every counter back to zero while keeping its name.
func reset_stats() -> void:
	for key: String in stats:
		stats[key] = 0.0 if typeof(stats[key]) == TYPE_FLOAT else 0


func step() -> void:
	if paused:
		return
	tick += 1
	trains.update()
	circuits.update()
	day.tick()
	statistics.advance(tick)
	_update_belts()
	_update_splitters()
	_update_underground_belts()
	_update_inserters()
	_update_miners()
	_update_crafting_machines()
	_update_labs()
	_update_fluid_machines()
	_update_logistics()
	if alerts.update(world, self):
		alerts_changed.emit()
	_update_pollution()
	_pollution_produced += pollution.total() / 60.0
	_update_enemies()
	_update_turrets()
	fluids.update()
	power.update()
	stats["power_generation"] = power.total_generation
	stats["power_demand"] = power.total_demand


func mark_power_dirty() -> void:
	power.mark_dirty()


# --------------------------------------------------------------------------
# belts
# --------------------------------------------------------------------------

func _update_belts() -> void:
	var belts: Array = live_of_type("transport-belt")
	stats["belts"] = belts.size()
	var item_count := 0
	for belt: Entity in belts:
		BeltSim.update(world, belt)
		item_count += BeltSim.items_of(belt).size()
	stats["belt_items"] = item_count


# --------------------------------------------------------------------------
# belt junctions
# --------------------------------------------------------------------------

## The two tiles a splitter straddles, as ``{ axis, forward }`` offsets.
##
## A splitter is two tiles wide across its heading, so the pair of tiles is
## found by walking sideways; both the inputs and the outputs are one step
## further along the heading.
static func splitter_tiles(splitter: Entity) -> Dictionary:
	var forward := BeltSim.dir_vector(splitter.direction)
	var side := EntityVisuals.lane_offset_vector(splitter.direction)
	var axis := Vector2i(int(absf(side.x)), int(absf(side.y)))
	return {
		"axis": axis,
		"forward": forward,
		"left": splitter.origin,
		"right": splitter.origin + axis,
	}


## Splitters hand each item on to one of the two belts in front, alternating.
##
## Each belt lane is independent: an item travelling in the right lane may be
## split between the right lanes of both output belts, but it can never cross
## to the left lane.  That is what makes a splitter preserve lane flow instead
## of mixing the two sides.
func _update_splitters() -> void:
	for splitter: Entity in live_of_type("splitter"):
		var tiles := splitter_tiles(splitter)
		var forward: Vector2i = tiles["forward"]
		var outputs: Array = [
			(tiles["left"] as Vector2i) + forward,
			(tiles["right"] as Vector2i) + forward,
		]
		var inputs: Array = [
			(tiles["left"] as Vector2i) - forward,
			(tiles["right"] as Vector2i) - forward,
		]
		# One round-robin cursor per lane.  Old saves used a single int.
		var next: Array = [0, 0]
		var saved: Variant = splitter.state.get("next", null)
		if saved is Array and (saved as Array).size() >= 2:
			next = [int((saved as Array)[0]), int((saved as Array)[1])]
		elif saved is int:
			next = [int(saved), int(saved)]
		for lane in BeltSim.LANES:
			var moved := false
			var start := int(next[lane])
			for attempt in 2:
				var out_index := (start + attempt) % 2
				var out_belt := world.entity_at(outputs[out_index])
				if not BeltSim.is_belt(out_belt):
					continue
				# Prefer the input on the same side, then the other belt.
				# Both must supply the same lane we are about to fill.
				for in_index: int in [out_index, 1 - out_index]:
					var in_belt := world.entity_at(inputs[in_index])
					if not BeltSim.is_belt(in_belt):
						continue
					var item := _belt_ready_item(in_belt, lane)
					if item.is_empty():
						continue
					# `false`: never fall back to the other lane.  Crossing
					# lanes here was the source of items appearing on the
					# wrong side of a splitter.
					if BeltSim.try_insert(out_belt, str(item["name"]),
							int(item["count"]), lane, false) <= 0:
						continue
					BeltSim.take_one(in_belt, lane)
					next[lane] = 1 - out_index
					stats["split"] = int(stats.get("split", 0)) + 1
					moved = true
					break
				if moved:
					break
		splitter.state["next"] = next


## The leading item of a belt, but only once it has reached the far end.
## ``lane`` limits the search to one belt lane (-1 means either lane).
static func _belt_ready_item(belt: Entity, lane := -1) -> Dictionary:
	var best: Dictionary = {}
	for item: Dictionary in BeltSim.items_of(belt):
		# Underground tunnel items use `travel` and have no lane/pos.
		if not item.has("pos") or not item.has("lane"):
			continue
		if float(item["pos"]) < 0.75:
			continue
		if lane >= 0 and int(item["lane"]) != lane:
			continue
		if best.is_empty() or float(item["pos"]) > float(best["pos"]):
			best = item
	return best


## The other half of an underground belt pair, from either end.
##
## Hovering an entrance looks forward for its exit; hovering the exit looks
## back for its entrance.  The renderer uses this for the yellow link line.
func underground_link(entity: Entity) -> Entity:
	if entity == null or entity.proto_type != "underground-belt":
		return null
	if str(entity.state.get("io", "input")) != "output":
		return _underground_partner(entity)
	var proto := entity.prototype()
	var max_distance := int(proto.get("max_distance", 5))
	var step := BeltSim.dir_vector(entity.direction)
	for k in range(1, max_distance + 1):
		var other := world.entity_at(entity.origin - step * k)
		if other == null:
			continue
		if other.proto_type != "underground-belt" or other.name != entity.name:
			continue
		if posmod(other.direction, 16) != posmod(entity.direction, 16):
			continue
		if str(other.state.get("io", "input")) == "input":
			return other
	return null


## The exit an underground belt entrance leads to, or ``null``.
func _underground_partner(entrance: Entity) -> Entity:
	var proto := entrance.prototype()
	var max_distance := int(proto.get("max_distance", 5))
	var step := BeltSim.dir_vector(entrance.direction)
	for k in range(1, max_distance + 1):
		var other := world.entity_at(entrance.origin + step * k)
		if other == null:
			continue
		if other.proto_type != "underground-belt" or other.name != entrance.name:
			continue
		if posmod(other.direction, 16) != posmod(entrance.direction, 16):
			continue
		if str(other.state.get("io", "input")) == "output":
			return other
	return null


## Underground belts swallow items at one end and spit them out at the other.
##
## ``max_distance`` from the prototype is how far a pair may be apart; the item
## rides the tunnel at the belt's speed, so a longer tunnel takes longer.
func _update_underground_belts() -> void:
	for belt: Entity in live_of_type("underground-belt"):
		if str(belt.state.get("io", "input")) != "input":
			continue
		var exit := _underground_partner(belt)
		if exit == null:
			continue
		var proto := belt.prototype()
		var speed := float(proto.get("speed", 0.03125))
		var span := float((exit.origin - belt.origin).length())
		if span <= 0.0:
			continue

		# A normal belt item can land in this state when a splitter/inserter
		# feeds an underground half, or when the player rotates a half that
		# was an exit into an entrance.  Tunnel items use `travel`, not
		# `lane`/`pos`; convert anything else instead of crashing on the
		# missing key.  Each lane keeps its own queue so a blocked right lane
		# cannot stall the left one.
		var lanes: Array = [[], []]
		var raw: Variant = belt.state.get("items", [])
		if raw is Array:
			for entry: Variant in raw:
				if not (entry is Dictionary):
					continue
				var item: Dictionary = entry
				var item_lane := int(item.get("lane", 0))
				if item_lane < 0 or item_lane >= BeltSim.LANES:
					item_lane = 0
				if item.has("travel"):
					item["lane"] = item_lane
					(lanes[item_lane] as Array).append(item)
				elif item.has("name") and item.has("count"):
					(lanes[item_lane] as Array).append({"name": str(item["name"]),
						"count": int(item["count"]), "travel": 0.0,
						"lane": item_lane})

		var behind := world.entity_at(
			belt.origin - BeltSim.dir_vector(belt.direction))
		for lane in BeltSim.LANES:
			var queue: Array = lanes[lane]
			# Push whatever has arrived out of the far end.  Keep the lane the
			# item entered on: it must leave on that same lane, not be balanced
			# to whichever output lane happens to have room.
			while not queue.is_empty() and float(queue[0]["travel"]) >= span:
				var ahead := world.entity_at(
					exit.origin + BeltSim.dir_vector(exit.direction))
				if not BeltSim.is_belt(ahead):
					break
				var head: Dictionary = queue[0]
				if BeltSim.try_insert(ahead, str(head["name"]),
						int(head["count"]), lane, false) <= 0:
					break
				queue.remove_at(0)
				stats["tunnelled"] = int(stats.get("tunnelled", 0)) + int(head["count"])

			# Advance this lane's queue with its own spacing.
			for index in queue.size():
				var item: Dictionary = queue[index]
				var limit := span
				if index > 0:
					limit = float(queue[index - 1]["travel"]) - BeltSim.SPACING
				item["travel"] = minf(limit, float(item["travel"]) + speed)

			# Take one more from the belt feeding the entrance, same lane.
			if not BeltSim.is_belt(behind):
				continue
			var room := span
			if not queue.is_empty():
				room = float(queue[queue.size() - 1]["travel"])
			if room < BeltSim.SPACING:
				continue
			var ready := _belt_ready_item(behind, lane)
			if ready.is_empty():
				continue
			var taken := BeltSim.take_one(behind, lane)
			if not taken.is_empty():
				queue.append({"name": str(taken["name"]),
					"count": int(taken["count"]), "travel": 0.0, "lane": lane})

		var flat: Array = []
		for lane in BeltSim.LANES:
			flat.append_array(lanes[lane])
		belt.state["items"] = flat


# --------------------------------------------------------------------------
# inserters
# --------------------------------------------------------------------------

## Inserter local coordinates are expressed with "front" at -y, so a plain
## rotation by the entity's direction maps them into the world.
static func rotate_local(local: Vector2, direction: int) -> Vector2:
	var angle := deg_to_rad(float(posmod(direction, 16)) * 22.5)
	return Vector2(local.x * cos(angle) - local.y * sin(angle),
		local.x * sin(angle) + local.y * cos(angle))


func _update_inserters() -> void:
	var inserters: Array = live_of_type("inserter")
	stats["inserters"] = inserters.size()
	for inserter: Entity in inserters:
		_update_inserter(inserter)


func _update_inserter(inserter: Entity) -> void:
	var proto := inserter.prototype()
	if proto.is_empty():
		return
	if not inserter.state.has("hand"):
		inserter.state["hand"] = {}
		inserter.state["swing"] = 0.0

	var hand: Dictionary = inserter.state["hand"]
	var swing := float(inserter.state.get("swing", 0.0))

	# A burner inserter refuels itself before it carries anything onward.  This
	# also lets an existing, completely empty burner inserter start itself from
	# a coal belt instead of being stuck forever.
	if Energy.is_burner(proto) and _try_self_fuel(inserter, proto):
		return

	# Inserters without power stop where they are.
	var speed_scale := 1.0
	if Energy.is_electric(proto):
		speed_scale = power.satisfaction_for(inserter)
		if speed_scale <= 0.0:
			return
	elif Energy.is_burner(proto):
		if not _burner_available(inserter):
			return

	var rotation_speed := float(proto.get("rotation_speed", 0.014))
	# `rotation_speed` is rotations per tick and a swing is half a rotation.
	var swing_ticks := 0.5 / maxf(rotation_speed, 1e-6)
	var swing_step := (1.0 / swing_ticks) * speed_scale

	var pickup_cell := _inserter_cell(inserter, proto, "pickup_position")
	var insert_cell := _inserter_cell(inserter, proto, "insert_position")

	if hand.is_empty():
		if swing > 0.0:
			swing = maxf(0.0, swing - swing_step)
			inserter.state["swing"] = swing
			return
		# Arm is at the pickup side: try to grab something we can also place.
		var source := world.entity_at(pickup_cell)
		var destination := world.entity_at(insert_cell)
		if source == null or destination == null:
			return
		var candidate := _peek_source(source, destination, pickup_cell, insert_cell, inserter)
		if candidate.is_empty():
			return
		# An inserter carries `hand_size` items, one for the plain inserter,
		# plus whatever the inserter capacity research has added.
		var carry := maxi(1, int(floor(float(proto.get("hand_size", 1.0)))))
		if research != null and research.modifiers != null:
			carry += research.modifiers.inserter_capacity
		var wanted: int = mini(carry, int(candidate["count"]))
		var taken := _take_from(source, str(candidate["name"]), wanted,
			pickup_cell, inserter)
		if taken <= 0:
			return
		inserter.state["hand"] = {"name": str(candidate["name"]), "count": taken}
		inserter.state["swing"] = 0.0
		_consume_inserter_energy(inserter, proto)
		return

	# Carrying: swing towards the destination.
	swing = minf(1.0, swing + swing_step)
	inserter.state["swing"] = swing
	if swing < 1.0:
		return
	var target := world.entity_at(insert_cell)
	if target == null:
		return
	var placed := _insert_into(target, str(hand["name"]), int(hand["count"]), insert_cell,
		inserter)
	if placed <= 0:
		return
	hand["count"] = int(hand["count"]) - placed
	if int(hand["count"]) <= 0:
		inserter.state["hand"] = {}
		# A belt receives the hand one item per tick; the arm rotation is paid
		# for once, when the last item leaves the hand.
		_consume_inserter_energy(inserter, proto)


## Pull one fuel item from the inserter's pickup target into its own fuel
## inventory.  Returns true when the arm spent this tick on refuelling.
func _try_self_fuel(inserter: Entity, proto: Dictionary) -> bool:
	var fuel_inventory := InventoryLayout.get_inventory(inserter, InventoryLayout.FUEL)
	if fuel_inventory == null or fuel_inventory.capacity <= 0:
		return false
	# Only refuel when the inserter has actually run dry.  Filling a spare
	# stack at every opportunity would make it eat the coal belt forever and
	# never carry fuel to the boiler.
	if not fuel_inventory.peek().is_empty():
		return false
	if float(inserter.state.get("burn_energy", 0.0)) > 0.0:
		return false
	var pickup_cell := _inserter_cell(inserter, proto, "pickup_position")
	var source := world.entity_at(pickup_cell)
	if source == null:
		return false
	var candidate := _peek_output(source, pickup_cell, inserter)
	var item_name := str(candidate.get("name", ""))
	if item_name.is_empty() or not Energy.is_fuel(item_name):
		return false
	if fuel_inventory.can_accept(item_name, 1) <= 0:
		return false
	var taken := _take_from(source, item_name, 1, pickup_cell, inserter)
	if taken <= 0:
		return false
	fuel_inventory.insert(item_name, taken)
	# Picking up the fuel costs the same arm motion as an ordinary grab.
	_consume_inserter_energy(inserter, proto)
	return true


func _consume_inserter_energy(inserter: Entity, proto: Dictionary) -> void:
	if not Energy.is_burner(proto):
		return
	var cost := Energy.parse(proto.get("energy_per_rotation"), 5000.0) \
		+ Energy.parse(proto.get("energy_per_movement"), 5000.0)
	var budget := float(inserter.state.get("burn_energy", 0.0)) - cost
	inserter.state["burn_energy"] = maxf(0.0, budget)


func _burner_available(entity: Entity) -> bool:
	if float(entity.state.get("burn_energy", 0.0)) > 0.0:
		return true
	var fuel := InventoryLayout.get_inventory(entity, InventoryLayout.FUEL)
	if fuel == null:
		return false
	var item := fuel.peek()
	if item.is_empty():
		return false
	var value := Energy.fuel_value(str(item["name"]))
	if value <= 0.0:
		return false
	fuel.extract(str(item["name"]), 1)
	entity.state["burn_energy"] = value
	return true


func _inserter_cell(inserter: Entity, proto: Dictionary, key: String) -> Vector2i:
	var local := FactorioAssets.parse_vector(proto.get(key, [0.0, 0.0]))
	var world_offset := rotate_local(local, inserter.direction)
	var position := inserter.center() + world_offset
	return Vector2i(int(floor(position.x)), int(floor(position.y)))


## What an inserter would like to move: the source's leading item, as long as
## the destination can take it.
func _peek_source(source: Entity, destination: Entity, pickup_cell: Vector2i,
		insert_cell: Vector2i, inserter: Entity) -> Dictionary:
	var candidate := _peek_output(source, pickup_cell, inserter)
	if candidate.is_empty():
		return {}
	if _can_insert(destination, str(candidate["name"]), insert_cell, inserter) <= 0:
		return {}
	return candidate


## Leading item of whatever the inserter is reaching into.
func _peek_output(entity: Entity, cell: Vector2i, inserter: Entity) -> Dictionary:
	if entity.proto_type == "item-entity":
		var count := int(entity.state.get("count", 0))
		var name := str(entity.state.get("item", ""))
		if count > 0 and not name.is_empty():
			return {"name": name, "count": count}
		return {}
	if BeltSim.is_belt(entity):
		# Inserters reach the lane on their side of the belt; one standing in
		# line with the belt (the end of a line) can reach either lane.
		var lane := BeltSim.lane_for_position(entity, inserter.center())
		var item := BeltSim.peek_one(entity, lane)
		if item.is_empty():
			item = BeltSim.peek_one(entity, 1 - lane)
		return item

	var type_name: String = str(entity.prototype().get("type", entity.proto_type))
	# Machines hand out their products first; chests just hand out contents.
	if type_name in ["furnace", "assembling-machine", "mining-drill", "rocket-silo"]:
		var output := InventoryLayout.get_inventory(entity, InventoryLayout.OUTPUT)
		if output != null:
			var item := output.peek()
			if not item.is_empty():
				return item
	var storage := InventoryLayout.get_inventory(entity, InventoryLayout.STORAGE)
	if storage != null:
		return storage.peek()
	# Machines never hand out their crafting ingredients or their fuel.
	return {}


func _take_from(entity: Entity, item_name: String, amount: int, cell: Vector2i,
		inserter: Entity) -> int:
	if entity.proto_type == "item-entity":
		var have := int(entity.state.get("count", 0))
		var taken := mini(have, amount)
		entity.state["count"] = have - taken
		if have - taken <= 0:
			world.remove_entity(entity)
		return taken
	if BeltSim.is_belt(entity):
		var lane := BeltSim.lane_for_position(entity, inserter.center())
		var taken := BeltSim.take_one(entity, lane)
		if taken.is_empty():
			taken = BeltSim.take_one(entity, 1 - lane)
		return int(taken.get("count", 0)) if not taken.is_empty() else 0
	var inventory := _primary_inventory(entity, item_name, false)
	if inventory == null:
		return 0
	return inventory.extract(item_name, amount)


## Which inventory of ``entity`` should receive ``item_name``.
func _primary_inventory(entity: Entity, item_name: String, for_input: bool) -> Inventory:
	var type_name: String = str(entity.prototype().get("type", entity.proto_type))
	var proto := entity.prototype()

	match type_name:
		"container", "logistic-container", "car", "spider-vehicle":
			return InventoryLayout.get_inventory(entity, InventoryLayout.STORAGE)
		"boiler", "reactor":
			return InventoryLayout.get_inventory(entity, InventoryLayout.FUEL)
		"furnace", "assembling-machine", "rocket-silo", "lab":
			# Fuel items go to the burner slot, everything else is an
			# ingredient for the current recipe.
			if for_input and Energy.is_burner(proto) and Energy.is_fuel(item_name):
				var fuel := InventoryLayout.get_inventory(entity, InventoryLayout.FUEL)
				if fuel != null and fuel.can_accept(item_name, 1) > 0:
					return fuel
			if for_input:
				return InventoryLayout.get_inventory(entity, InventoryLayout.INPUT)
			return InventoryLayout.get_inventory(entity, InventoryLayout.OUTPUT)
		"mining-drill":
			# A burner drill has a real fuel slot and accepts coal there, just
			# like a furnace.  Only the output slot is used when the caller is
			# taking items out.
			if for_input and Energy.is_burner(proto) and Energy.is_fuel(item_name):
				var fuel := InventoryLayout.get_inventory(entity, InventoryLayout.FUEL)
				if fuel != null and fuel.can_accept(item_name, 1) > 0:
					return fuel
			return InventoryLayout.get_inventory(entity, InventoryLayout.OUTPUT)
		"ammo-turret", "electric-turret", "artillery-turret":
			return InventoryLayout.get_inventory(entity, InventoryLayout.FUEL)
	if for_input:
		return InventoryLayout.get_inventory(entity, InventoryLayout.INPUT)
	return InventoryLayout.get_inventory(entity, InventoryLayout.OUTPUT)


func _can_insert(entity: Entity, item_name: String, cell: Vector2i,
		inserter: Entity) -> int:
	if BeltSim.is_belt(entity):
		# Belt positions are in world pixels; the cell alone cannot say which
		# lane the inserter is on, so ask the inserter.
		var lane := BeltSim.lane_for_position(entity, inserter.center())
		if BeltSim.lane_has_space(entity, lane) or BeltSim.lane_has_space(entity, 1 - lane):
			return 1
		return 0
	# An inserter only moves an item into a machine that will actually process
	# it.  Capacity alone is not enough: a chest accepts anything, but a
	# furnace must want the ore (or burn it) and an assembler must have it in
	# the recipe.  Otherwise inserters happily stuff unrelated items into the
	# first machine they point at.
	if not _accepts_input(entity, item_name):
		return 0
	var inventory := _primary_inventory(entity, item_name, true)
	if inventory == null:
		return 0
	return inventory.can_accept(item_name, 1)


## Whether ``entity`` can process ``item_name`` as an ingredient, fuel, module
## or ammunition.  Chests and train cargo are the deliberate exceptions: they
## store anything.
func _accepts_input(entity: Entity, item_name: String) -> bool:
	var proto := entity.prototype()
	var type_name: String = str(proto.get("type", entity.proto_type))
	match type_name:
		"container", "logistic-container", "car", "spider-vehicle", \
				"locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon":
			return true
		"furnace":
			if Energy.is_fuel(item_name):
				return true
			return _ingredient_accepted_by(entity, ["smelting"], item_name)
		"assembling-machine", "rocket-silo":
			var categories: Variant = proto.get("crafting_categories", [])
			if type_name == "rocket-silo":
				# The silo's own recipe set is the authoritative one.
				categories = ["rocket-building", "crafting"]
			return _ingredient_accepted_by(entity, categories, item_name)
		"lab":
			var inputs: Variant = proto.get("inputs", [])
			return inputs is Array and (inputs as Array).has(item_name)
		"boiler", "reactor", "generator":
			return Energy.is_fuel(item_name)
		"beacon":
			return not Prototypes.get_p("module", item_name).is_empty()
		"roboport":
			return not Prototypes.get_p("repair-tool", item_name).is_empty() \
				or not Prototypes.get_p("construction-robot", item_name).is_empty() \
				or not Prototypes.get_p("logistic-robot", item_name).is_empty()
		"ammo-turret", "electric-turret", "artillery-turret":
			return _ammo_fits_turret(proto, item_name)
		"mining-drill":
			# Burner drills burn fuel; electric drills have no fuel slot and
			# therefore accept nothing from an inserter or a neighbour drill.
			return Energy.is_burner(proto) and Energy.is_fuel(item_name)
		"solar-panel", "accumulator", "radar", "train-stop", \
				"electric-pole", "pipe", "pipe-to-ground", "pump", \
				"storage-tank", "wall", "gate", "land-mine":
			return false
	# Unknown machine types: be conservative and only accept fuel.
	return Energy.is_fuel(item_name)


## Is the item an ingredient of the machine's current recipe, or of any recipe
## in its crafting categories when it has no recipe yet?
func _ingredient_accepted_by(entity: Entity, categories: Variant,
		item_name: String) -> bool:
	var recipe_name := str(entity.state.get("recipe", ""))
	if not recipe_name.is_empty():
		return _recipe_uses_item(recipe_name, item_name)
	if not (categories is Array):
		return false
	return _category_ingredients(categories).has(item_name)


## Cached set of item names that some recipe of these categories consumes.
static var _category_ingredient_cache: Dictionary = {}


func _category_ingredients(categories: Array) -> Dictionary:
	var key := "|".join(categories)
	var cached: Variant = _category_ingredient_cache.get(key)
	if cached != null:
		return cached
	var items: Dictionary = {}
	for category: Variant in categories:
		for recipe_name: String in Prototypes.recipes_in_category(str(category)):
			for ingredient: Dictionary in Prototypes.recipe_ingredients(
					Prototypes.get_p("recipe", recipe_name)):
				if str(ingredient.get("type", "item")) != "fluid":
					items[str(ingredient["name"])] = true
	_category_ingredient_cache[key] = items
	return items


func _recipe_uses_item(recipe_name: String, item_name: String) -> bool:
	for ingredient: Dictionary in Prototypes.recipe_ingredients(
			Prototypes.get_p("recipe", recipe_name)):
		if str(ingredient.get("type", "item")) != "fluid" \
				and str(ingredient["name"]) == item_name:
			return true
	return false


func _ammo_fits_turret(proto: Dictionary, item_name: String) -> bool:
	var ammo := Prototypes.get_p("ammo", item_name)
	if ammo.is_empty():
		return false
	var wanted := str((proto.get("attack_parameters", {}) as Dictionary).get(
		"ammo_category", ""))
	var categories: Variant = proto.get("ammo_categories", [])
	if wanted.is_empty() and categories is Array and not (categories as Array).is_empty():
		return (categories as Array).has(str(ammo.get("ammo_category", "")))
	return str(ammo.get("ammo_category", "")) == wanted


func _insert_into(entity: Entity, item_name: String, amount: int, cell: Vector2i,
		inserter: Entity) -> int:
	if BeltSim.is_belt(entity):
		# Factorio inserters do not put a whole carried stack onto a belt as a
		# single belt item.  They drop the hand one item at a time; keep the
		# rest in the hand and let the next ticks finish the same swing.
		var lane := BeltSim.lane_for_position(entity, inserter.center())
		return BeltSim.try_insert(entity, item_name, mini(amount, 1), lane)
	var inventory := _primary_inventory(entity, item_name, true)
	if inventory == null:
		return 0
	var leftover := inventory.insert(item_name, amount)
	return amount - leftover


# --------------------------------------------------------------------------
# mining drills
# --------------------------------------------------------------------------

func _update_miners() -> void:
	for drill: Entity in live_of_type("mining-drill"):
		_update_miner(drill)


func _update_miner(drill: Entity) -> void:
	var proto := drill.prototype()
	if proto.is_empty():
		return
	if not _machine_may_run(drill, proto):
		return

	var target := _find_ore_under(drill, proto)
	if target.is_empty():
		drill.state["progress"] = 0.0
		return

	var resource := Prototypes.get_p("resource", str(target["name"]))
	var minable: Variant = resource.get("minable", {})
	var mining_time := 1.0
	var results: Array = []
	if minable is Dictionary:
		mining_time = float(minable.get("mining_time", 1.0))
		results = minable.get("results", [])
		if results.is_empty() and minable.has("result"):
			results = [{"name": minable["result"], "amount": minable.get("count", 1)}]
	if results.is_empty():
		results = [{"name": str(target["name"]), "amount": 1}]

	var mining_speed := float(proto.get("mining_speed", 0.5))
	var rate := mining_speed / maxf(mining_time, 1e-6) / TICKS_PER_SECOND
	rate *= _satisfaction(drill, proto)
	drill.state["working_tick"] = tick
	var progress := float(drill.state.get("progress", 0.0)) + rate
	if progress < 1.0:
		drill.state["progress"] = progress
		return

	# One mining cycle is ready: move the products into the drill's output.
	# A pumpjack produces fluid instead of items, so both kinds are handled.
	var output := InventoryLayout.get_inventory(drill, InventoryLayout.OUTPUT)
	var produced := false
	var infinite := bool(resource.get("infinite", false))
	var floor_amount := float(resource.get("minimum", 0.0)) if infinite else 0.0

	for result: Dictionary in results:
		var item_name := str(result.get("name", target["name"]))
		var available := float(world.ore_at(target["cell"])["amount"])
		if available < 1.0 and not infinite:
			continue

		if str(result.get("type", "item")) == "fluid":
			# Yield falls off as an infinite well depletes, down to a floor.
			var yield_scale := 1.0
			if infinite:
				var normal := maxf(1.0, float(resource.get("normal", available)))
				yield_scale = clampf(available / normal, 0.1, 1.0)
			var amount := float(result.get("amount", result.get("amount_min", 1)))
			var box := _output_fluid_box(drill)
			if box.is_empty():
				continue
			var accepted: float = fluids.add(drill, box, item_name, amount * yield_scale, 15.0)
			if accepted <= 0.0:
				continue
			drill.state["working_tick"] = tick
			_deplete(world, target["cell"], float(result.get("amount_min", amount)) * yield_scale,
				infinite, floor_amount)
			produced = true
			continue

		var wanted := int(result.get("amount", 1))
		# A drill drops its ore in front of the output chute.  The local
		# `vector_to_place_result` is rotated by the drill's direction, so R
		# chooses the side.  Belts take the item directly; otherwise it becomes
		# an item stack on the ground, which is what Factorio does when there is
		# no belt in front.
		var output_cell := _drill_output_cell(drill, proto)
		var output_entity: Entity = world.entity_at(output_cell)
		var direct_belt: Entity = output_entity
		if direct_belt != null and (direct_belt.is_ghost() \
				or not BeltSim.is_belt(direct_belt)):
			direct_belt = null
		var belt_room := direct_belt != null \
			and (BeltSim.lane_has_space(direct_belt, 0) \
				or BeltSim.lane_has_space(direct_belt, 1))
		# A drill also feeds a container or machine directly: a chest, a
		# furnace's input, an assembler's ingredient slots.  BeltSim is not the
		# only possible target in front of the output chute.
		var direct_target: Entity = null
		var target_inventory: Inventory = null
		if direct_belt == null and output_entity != null \
				and not output_entity.is_ghost() \
				and output_entity.proto_type != "item-entity" \
				and _accepts_input(output_entity, item_name):
			var candidate := _primary_inventory(output_entity, item_name, true)
			if candidate != null and candidate.can_accept(item_name, wanted) >= wanted:
				direct_target = output_entity
				target_inventory = candidate
		var ground_target := output_entity
		var ground_ok := direct_belt == null and direct_target == null \
			and not _is_water_cell(output_cell) \
			and (ground_target == null \
				or (ground_target.proto_type == "item-entity" \
					and str(ground_target.state.get("item", "")) == item_name))
		if not belt_room and direct_target == null and not ground_ok \
				and (output == null \
					or output.can_accept(item_name, wanted) < wanted):
			continue
		if available < 1.0:
			continue
		var mined := int(minf(available, float(wanted)))
		# Mining productivity pays out extra ore without taking it out of the
		# ground, exactly as Factorio's bonus does.
		if research != null and research.modifiers != null:
			var bonus := research.modifiers.mining_productivity
			var extra := int(floor(float(mined) * bonus))
			if extra > 0:
				mined += extra
		_deplete(world, target["cell"], float(wanted), infinite, floor_amount)
		var moved := 0
		if belt_room:
			moved = BeltSim.try_insert(direct_belt, item_name, mined)
		elif direct_target != null and target_inventory != null:
			var leftover := target_inventory.insert(item_name, mined)
			moved = mined - leftover
		elif ground_ok:
			if _drop_on_ground(output_cell, item_name, mined):
				moved = mined
		if moved < mined and output != null:
			output.insert(item_name, mined - moved)
		stats["mined"] = int(stats["mined"]) + mined
		if statistics != null:
			statistics.record_produced(item_name, mined)
		item_mined.emit(target["cell"], item_name, mined)
		if research != null:
			research.on_item_produced(item_name, mined)
			research.on_entity_mined(str(target["name"]))
		produced = true
	if produced:
		drill.state["progress"] = 0.0
	else:
		# Nothing fitted: hold the completed cycle until there is room.
		drill.state["progress"] = 1.0


## Take ore out of the ground, never past an infinite well's floor.
func _deplete(world_: GameWorld, cell: Vector2i, amount: float, infinite: bool,
		floor_amount: float) -> void:
	if not infinite:
		world_.mine_ore(cell, amount)
		return
	var current := float(world_.ore_at(cell)["amount"])
	var allowed: float = maxf(0.0, current - maxf(floor_amount, 0.0))
	world_.mine_ore(cell, minf(amount, allowed))


## The box a drill pushes fluid into.  A pumpjack has a box literally called
## ``output_fluid_box``; other machines flag one with ``production_type``.
func _output_fluid_box(drill: Entity) -> String:
	var specs: Array = FluidSystem.box_specs(drill)
	for spec: Dictionary in specs:
		if str(spec["name"]) == FluidSystem.SECONDARY:
			return FluidSystem.SECONDARY
	for spec2: Dictionary in specs:
		if str(spec2["production_type"]) == "output":
			return str(spec2["name"])
	return str((specs[0] as Dictionary)["name"]) if not specs.is_empty() else ""


func _is_water_cell(cell: Vector2i) -> bool:
	var tile := world.tile_at(cell)
	return tile.begins_with("water") or tile.begins_with("deepwater")


## Put a stack of items on the ground, merging into an existing ground stack on
## the same tile.  Returns false when the tile is occupied by something else.
func _drop_on_ground(cell: Vector2i, item_name: String, amount: int) -> bool:
	if amount <= 0:
		return false
	var existing := world.entity_at(cell)
	if existing != null and existing.proto_type == "item-entity" \
			and str(existing.state.get("item", "")) == item_name:
		existing.state["count"] = int(existing.state.get("count", 0)) + amount
		return true
	if existing != null:
		return false
	var stack := Entity.create("item-entity", "item-on-ground", cell)
	stack.state["item"] = item_name
	stack.state["count"] = amount
	return world.place_entity(stack)


## The tile just outside a drill's output chute, in world cells.
func _drill_output_cell(drill: Entity, proto: Dictionary) -> Vector2i:
	var local := FactorioAssets.parse_vector(
		proto.get("vector_to_place_result", [0.0, -1.0]))
	var offset := rotate_local(local, drill.direction)
	var centre := drill.center()
	return Vector2i(int(floor(centre.x + offset.x)),
		int(floor(centre.y + offset.y)))


## Whether the drill has anything under it, for the alert scan.
func has_ore_under(drill: Entity) -> Dictionary:
	return _find_ore_under(drill, drill.prototype())


## First ore tile the drill can reach, honouring its resource categories.
func _find_ore_under(drill: Entity, proto: Dictionary) -> Dictionary:
	var categories: Array = proto.get("resource_categories", [])
	var radius := float(proto.get("resource_searching_radius", 2.49))
	var centre := drill.center()
	var reach := int(ceil(radius))
	var best := {}
	var best_distance := INF
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var cell := drill.origin + Vector2i(dx, dy)
			var ore := world.ore_at(cell)
			if str(ore["name"]).is_empty() or float(ore["amount"]) <= 0.0:
				continue
			var resource := Prototypes.get_p("resource", str(ore["name"]))
			if not _category_matches(resource, categories):
				continue
			# Distance is measured to the tile's centre; a pumpjack's 0.49 tile
			# search radius only reaches the tile it stands on.
			var distance := (Vector2(cell) + Vector2(0.5, 0.5)).distance_to(centre)
			if distance > radius or distance >= best_distance:
				continue
			best_distance = distance
			best = {"name": str(ore["name"]), "cell": cell}
	return best


static func _category_matches(resource: Dictionary, categories: Array) -> bool:
	if categories.is_empty():
		return true
	var own: Variant = resource.get("resource_categories", [])
	if own is Array:
		for category: Variant in own:
			if categories.has(category):
				return true
	# The category can live on the resource itself (crude oil is
	# ``basic-fluid``) or inside ``minable``; a missing one means basic-solid,
	# because the dump only stores what Lua set explicitly.
	if resource.has("category") and categories.has(str(resource["category"])):
		return true
	var minable: Variant = resource.get("minable", {})
	var category := "basic-solid"
	if minable is Dictionary and minable.has("category"):
		category = str(minable["category"])
	return categories.has(category)


# --------------------------------------------------------------------------
# crafting machines
# --------------------------------------------------------------------------

func _update_crafting_machines() -> void:
	# The rocket silo is a crafting machine too, and leaving it out meant a map
	# could never be finished.
	for type_name: String in ["furnace", "assembling-machine", "rocket-silo"]:
		for machine: Entity in live_of_type(type_name):
			_update_crafting_machine(machine)


func _update_crafting_machine(machine: Entity) -> void:
	var proto := machine.prototype()
	if proto.is_empty():
		return
	var input := InventoryLayout.get_inventory(machine, InventoryLayout.INPUT)
	var output := InventoryLayout.get_inventory(machine, InventoryLayout.OUTPUT)
	if input == null or output == null:
		return

	var recipe_name := str(machine.state.get("recipe", ""))
	if recipe_name.is_empty():
		recipe_name = _choose_recipe(proto, input, output)
		if recipe_name.is_empty():
			machine.state["progress"] = 0.0
			return
		machine.state["recipe"] = recipe_name

	var recipe := Prototypes.get_p("recipe", recipe_name)
	if recipe.is_empty():
		machine.state["recipe"] = ""
		return

	var ingredients := Prototypes.recipe_ingredients(recipe)
	var products := Prototypes.recipe_products(recipe)
	var box_map := fluid_box_map(machine, recipe)

	# Room for the products?  Factorio pauses when the output is full.
	for product: Dictionary in products:
		if str(product.get("type", "item")) == "fluid":
			if not _has_room_for_fluid(machine, product, box_map):
				return
			continue
		if str(product["name"]) == "rocket-part":
			# A part goes on the pad, so there is always room for it.
			continue
		if output.can_accept(str(product["name"]), int(product["amount"])) < int(product["amount"]):
			return

	var progress := float(machine.state.get("progress", 0.0))
	if progress <= 0.0:
		if not input.has_at_least(_item_ingredients(ingredients)):
			return
		if not _has_fluid_ingredients(machine, ingredients, box_map):
			return
		# Check power first, then take the ingredients, so a machine that
		# cannot run never swallows the player's resources.
		if not _machine_may_run(machine, proto, false):
			return
		if not _consume_ingredients(input, ingredients):
			return
		_consume_fluid_ingredients(machine, ingredients, box_map)
		machine.state["consumed"] = true

	if not _machine_may_run(machine, proto, true):
		return
	machine.state["working_tick"] = tick

	var crafting_speed := float(proto.get("crafting_speed", 1.0))
	var seconds := Prototypes.recipe_energy(recipe) / maxf(crafting_speed, 1e-6)
	progress += (1.0 / maxf(seconds * TICKS_PER_SECOND, 1.0)) * _satisfaction(machine, proto)

	if progress < 1.0:
		machine.state["progress"] = progress
		return

	for product: Dictionary in products:
		if str(product.get("type", "item")) == "fluid":
			_add_fluid(machine, product, float(product.get("amount", 0.0)), box_map)
			continue
		if str(product["name"]) == "rocket-part":
			# Parts are a count on the pad, not a stack in a slot: a rocket
			# needs fifty and a stack holds five.
			machine.state["rocket_parts"] = int(
				machine.state.get("rocket_parts", 0)) + int(product["amount"])
		else:
			output.insert(str(product["name"]), int(product["amount"]))
		if statistics != null:
			statistics.record_produced(str(product["name"]),
				int(product["amount"]))
		# Machine output counts towards trigger technologies too.
		if research != null:
			research.on_item_produced(str(product["name"]), int(product["amount"]))
	machine.state["progress"] = 0.0
	stats["crafts"] = int(stats["crafts"]) + 1
	if str(recipe.get("category", "")) != "smelting":
		# Assemblers keep their recipe; furnaces re-pick from what is left.
		pass


## How many parts a rocket needs before it can go.
static func rocket_parts_required() -> int:
	return int(Prototypes.get_p("rocket-silo", "rocket-silo").get(
		"rocket_parts_required", 50))


## How many rocket parts a silo has finished and is holding.
func rocket_parts(silo: Entity) -> int:
	return int(silo.state.get("rocket_parts", 0))


## Whether a silo has a complete rocket on the pad.
func rocket_ready(silo: Entity) -> bool:
	return rocket_parts(silo) >= rocket_parts_required()


## Launch a rocket.  Returns ``{ launched, number }``.
##
## A rocket is built out of parts and then leaves: the parts are consumed, the
## count of launches goes up, and the first one wins the map.  There is nothing
## to land it on — Space Age's platforms are not modelled — so the reward is the
## launch itself, which is what the base game's victory is.
func launch_rocket(silo: Entity) -> Dictionary:
	if silo == null or silo.proto_type != "rocket-silo":
		return {"launched": false, "reason": "not a silo"}
	var required := rocket_parts_required()
	if not rocket_ready(silo):
		return {"launched": false, "reason": "not enough parts",
			"parts": rocket_parts(silo), "required": required}
	silo.state["rocket_parts"] = maxi(0, rocket_parts(silo) - required)
	rockets_launched += 1
	silo.state["launches"] = int(silo.state.get("launches", 0)) + 1
	silo.state["launch_flash"] = 30
	rocket_launched.emit(rockets_launched)
	if rockets_launched == 1:
		victory_announced = true
	return {"launched": true, "number": rockets_launched,
		"parts": required, "required": required}


## The solid half of a recipe's ingredient list.
static func _item_ingredients(ingredients: Array) -> Array:
	var items: Array = []
	for ingredient: Dictionary in ingredients:
		if str(ingredient.get("type", "item")) != "fluid":
			items.append(ingredient)
	return items


func _consume_ingredients(input: Inventory, ingredients: Array) -> bool:
	var items := _item_ingredients(ingredients)
	if not input.has_at_least(items):
		return false
	for ingredient: Dictionary in items:
		input.extract(str(ingredient["name"]), int(ingredient["amount"]))
		if statistics != null:
			statistics.record_consumed(str(ingredient["name"]),
				int(ingredient["amount"]))
	return true


# --------------------------------------------------------------------------
# fluids
# --------------------------------------------------------------------------

## Work out which physical box each fluid of a recipe belongs in.
##
## Only a few recipes spell it out with ``fluidbox_index`` (basic oil
## processing does).  The rest leave it to the engine, which hands fluid
## ingredients to the machine's input boxes in order and fluid products to its
## output boxes in order — so a chemical plant's water goes to box 0 and its
## acid leaves from box 2.
##
## Returns ``{ "in:<fluid>": box, "out:<fluid>": box }``.
static func fluid_box_map(entity: Entity, recipe: Dictionary) -> Dictionary:
	var inputs: Array = []
	var outputs: Array = []
	for spec: Dictionary in FluidSystem.box_specs(entity):
		if str(spec["production_type"]) == "output":
			outputs.append(str(spec["name"]))
		else:
			inputs.append(str(spec["name"]))

	var map: Dictionary = {}
	var cursors := {"in": 0, "out": 0}
	var pools := {"in": inputs, "out": outputs}
	for is_product: bool in [false, true]:
		var side := "out" if is_product else "in"
		var pool: Array = pools[side]
		var entries: Array = Prototypes.recipe_products(recipe) if is_product \
			else Prototypes.recipe_ingredients(recipe)
		for entry: Dictionary in entries:
			if str(entry.get("type", "item")) != "fluid":
				continue
			var key := "%s:%s" % [side, str(entry["name"])]
			if map.has(key):
				continue
			if entry.has("fluidbox_index"):
				var explicit := "fluid_box_%d" % int(entry["fluidbox_index"])
				if not FluidSystem.spec_of(entity, explicit).is_empty():
					map[key] = explicit
					continue
			var cursor: int = int(cursors[side])
			if cursor < pool.size():
				map[key] = pool[cursor]
				cursors[side] = cursor + 1
	return map


## Which fluid box one recipe entry uses, given a map from ``fluid_box_map``.
static func fluid_box_for(entity: Entity, entry: Dictionary, box_map := {},
		is_product := false) -> String:
	var side := "out" if is_product else "in"
	var key := "%s:%s" % [side, str(entry.get("name", ""))]
	if box_map.has(key):
		return str(box_map[key])
	if entry.has("fluidbox_index"):
		var name := "fluid_box_%d" % int(entry["fluidbox_index"])
		if not FluidSystem.spec_of(entity, name).is_empty():
			return name
	for spec: Dictionary in FluidSystem.box_specs(entity):
		if str(spec["name"]) == FluidSystem.PRIMARY:
			return FluidSystem.PRIMARY
	var specs: Array = FluidSystem.box_specs(entity)
	return str((specs[0] as Dictionary)["name"]) if not specs.is_empty() else ""


func _has_fluid_ingredients(machine: Entity, ingredients: Array, box_map: Dictionary) -> bool:
	for ingredient: Dictionary in ingredients:
		if str(ingredient.get("type", "item")) != "fluid":
			continue
		var box := fluid_box_for(machine, ingredient, box_map, false)
		if box.is_empty():
			return false
		if string_fluid(machine, box) != str(ingredient["name"]):
			return false
		if fluids.amount_in(machine, box) < float(ingredient["amount"]) - 1e-4:
			return false
	return true


## Fluid of the whole network a box belongs to (a pipe network is one tank).
func string_fluid(entity: Entity, box_name: String) -> String:
	return str(fluids.aggregate(entity, box_name)["fluid"])


func _consume_fluid_ingredients(machine: Entity, ingredients: Array,
		box_map: Dictionary) -> void:
	for ingredient: Dictionary in ingredients:
		if str(ingredient.get("type", "item")) != "fluid":
			continue
		var box := fluid_box_for(machine, ingredient, box_map, false)
		if box.is_empty():
			continue
		fluids.take(machine, box, str(ingredient["name"]), float(ingredient["amount"]))


func _has_room_for_fluid(machine: Entity, product: Dictionary,
		box_map: Dictionary) -> bool:
	var box := fluid_box_for(machine, product, box_map, true)
	if box.is_empty():
		return false
	var state := fluids.aggregate(machine, box)
	var fluid := str(state["fluid"])
	if not fluid.is_empty() and fluid != str(product["name"]):
		return false
	return float(state["capacity"]) - float(state["amount"]) >= float(product.get("amount", 0.0)) - 1e-4


func _add_fluid(machine: Entity, product: Dictionary, amount: float,
		box_map: Dictionary) -> float:
	var box := fluid_box_for(machine, product, box_map, true)
	if box.is_empty():
		return 0.0
	return fluids.add(machine, box, str(product["name"]), amount, 15.0)


# --------------------------------------------------------------------------
# fluid machines
# --------------------------------------------------------------------------

func _update_fluid_machines() -> void:
	for pump: Entity in live_of_type("offshore-pump"):
		_update_offshore_pump(pump)
	for boiler: Entity in live_of_type("boiler"):
		_update_boiler(boiler)
	for engine: Entity in live_of_type("generator"):
		_update_steam_engine(engine)


## An offshore pump lifts water out of the lake it stands in.
##
## Factorio 2.0's ``pumping_speed`` is already in fluid units per tick:
## 20 for an offshore pump, i.e. 1200/s.  Scaling it by TICK_DELTA made the
## pump produce only 20/s, while one boiler needs 60/s (1/tick), so the boiler
## starved and the turbines never got steam.
func _update_offshore_pump(pump: Entity) -> void:
	var proto := pump.prototype()
	var per_tick := float(proto.get("pumping_speed", 20.0))
	if not _touches_water(pump):
		return
	var accepted := fluids.add(pump, FluidSystem.PRIMARY, "water",
		per_tick, 15.0)
	if accepted > 0.0:
		pump.state["working_tick"] = tick


func _touches_water(pump: Entity) -> bool:
	for cell: Vector2i in pump.occupied_cells():
		# An offshore pump stands *on* water; a single shoreline tile can be
		# surrounded by land, so its own tile counts too.
		var own := world.tile_at(cell)
		if own.begins_with("water") or own.begins_with("deepwater"):
			return true
		for offset: Vector2i in [Vector2i(0, -1), Vector2i(1, 0),
				Vector2i(0, 1), Vector2i(-1, 0)]:
			var tile := world.tile_at(cell + offset)
			if tile.begins_with("water") or tile.begins_with("deepwater"):
				return true
	return false


## A boiler burns fuel to turn water into steam.
##
## Its 1.8 MW exactly covers the energy the steam carries away, so the
## conversion rate falls out of the data:
## ``1.8MW / (200 J/K * (165C - 15C)) = 60 water a second`` — which is why one
## boiler feeds exactly two steam engines.
func _update_boiler(boiler: Entity) -> void:
	var proto := boiler.prototype()
	var target := float(proto.get("target_temperature", 165.0))
	var steam_heat := _fluid_heat_capacity("steam")
	var energy := Energy.usage(proto)
	if steam_heat <= 0.0 or target <= 15.0:
		return
	var per_tick := (energy / (steam_heat * (target - 15.0))) * TICK_DELTA
	if per_tick <= 0.0:
		return

	# Only burn fuel once there is water to heat and room for the steam.
	var inlet := FluidSystem.PRIMARY
	if fluids.aggregate(boiler, inlet)["fluid"] != "water":
		return
	if fluids.amount_in(boiler, inlet) < per_tick 			and float(fluids.aggregate(boiler, inlet)["amount"]) < per_tick:
		return
	var outlet := FluidSystem.SECONDARY
	var out_state := fluids.aggregate(boiler, outlet)
	var out_fluid := str(out_state["fluid"])
	if not out_fluid.is_empty() and out_fluid != "steam":
		return
	if float(out_state["capacity"]) - float(out_state["amount"]) < per_tick:
		return
	if not _machine_may_run(boiler, proto):
		return

	var water := fluids.take(boiler, inlet, "water", per_tick)
	if water <= 0.0:
		return
	fluids.add(boiler, outlet, "steam", water, target)
	boiler.state["working_tick"] = tick


## A steam engine converts the heat in steam into electricity.
##
## ``fluid_usage_per_tick`` 0.5 of 165C steam is 0.5 * 200 J/K * 150 K per tick,
## i.e. 900 kW — the number on the tin.
func _update_steam_engine(engine: Entity) -> void:
	var proto := engine.prototype()
	var usage := float(proto.get("fluid_usage_per_tick", 0.0))
	if usage <= 0.0:
		engine.state["available_power"] = 0.0
		return
	var box := FluidSystem.PRIMARY
	var state := fluids.aggregate(engine, box)
	if str(state["fluid"]) != "steam" or float(state["amount"]) < usage:
		engine.state["available_power"] = 0.0
		return
	var temperature := float(state["temperature"])
	var energy_per_unit := _fluid_heat_capacity("steam") * maxf(0.0, temperature - 15.0)
	if energy_per_unit <= 0.0:
		engine.state["available_power"] = 0.0
		return
	var taken := fluids.take(engine, box, "steam", usage)
	engine.state["available_power"] = taken * energy_per_unit / TICK_DELTA
	if taken > 0.0:
		engine.state["working_tick"] = tick


static func _fluid_heat_capacity(fluid: String) -> float:
	var proto := Prototypes.get_p("fluid", fluid)
	return Energy.parse(proto.get("heat_capacity"), 0.0)


## Auto-select the recipe a machine should run, mirroring Factorio's furnace
## behaviour: the first recipe of a matching category whose ingredients are
## available.
func _choose_recipe(proto: Dictionary, input: Inventory, output: Inventory) -> String:
	var categories: Array = proto.get("crafting_categories", [])
	if categories.is_empty() or input.is_empty():
		return ""
	var candidates: Array = []
	for category: Variant in categories:
		candidates.append_array(Prototypes.recipes_in_category(str(category)))
	var offered: Dictionary = {}
	for recipe_name: String in candidates:
		if offered.has(recipe_name):
			continue
		offered[recipe_name] = true
		var recipe := Prototypes.get_p("recipe", recipe_name)
		var ingredients := Prototypes.recipe_ingredients(recipe)
		if ingredients.is_empty():
			continue
		if not input.has_at_least(ingredients):
			continue
		var products := Prototypes.recipe_products(recipe)
		var fits := true
		for product: Dictionary in products:
			if output.can_accept(str(product["name"]), int(product["amount"])) < int(product["amount"]):
				fits = false
				break
		if fits:
			return recipe_name
	return ""


# --------------------------------------------------------------------------
# research
# --------------------------------------------------------------------------

## Labs turn science packs into progress on the technology being studied.
##
## A lab works only while it holds one of every ingredient the technology
## asks for; each finished unit consumes one of each, which is how Factorio
## makes science pack logistics the real cost of research.
func _update_labs() -> void:
	if research == null or research.current.is_empty():
		return
	var labs: Array = live_of_type("lab")
	if labs.is_empty():
		return

	var required := _required_packs()
	if required.is_empty():
		return

	var active: Array = []
	var work := 0.0
	for lab: Entity in labs:
		if not _machine_may_run(lab, lab.prototype(), false):
			continue
		if not _lab_holds(lab, required):
			continue
		active.append(lab)
		var lab_speed := float(lab.prototype().get("researching_speed", 1.0))
		if research.modifiers != null:
			lab_speed *= research.modifiers.research_speed_multiplier()
		work += lab_speed
	if active.is_empty():
		return

	# Labs draw power while they work.
	for lab: Entity in active:
		_machine_may_run(lab, lab.prototype(), true)
		lab.state["working_tick"] = tick

	research.add_work(work * TICK_DELTA, func() -> bool:
		return _consume_packs(active, required))


## ``[{ name, amount }]`` for the technology being studied.
func _required_packs() -> Array:
	var out: Array = []
	for entry: Variant in research.current_ingredients():
		if entry is Array and entry.size() >= 2:
			out.append({"name": str(entry[0]), "amount": maxi(1, int(entry[1]))})
		elif entry is Dictionary:
			out.append({"name": str(entry.get("name", "")),
				"amount": maxi(1, int(entry.get("amount", 1)))})
	return out


func _lab_holds(lab: Entity, required: Array) -> bool:
	var input := InventoryLayout.get_inventory(lab, InventoryLayout.INPUT)
	if input == null:
		return false
	for pack: Dictionary in required:
		if input.count_of(str(pack["name"])) < int(pack["amount"]):
			return false
	return true


## Take one unit's worth of science packs out of a lab that has them all.
func _consume_packs(active: Array, required: Array) -> bool:
	for lab: Entity in active:
		if not _lab_holds(lab, required):
			continue
		var input := InventoryLayout.get_inventory(lab, InventoryLayout.INPUT)
		for pack: Dictionary in required:
			input.extract(str(pack["name"]), int(pack["amount"]))
		return true
	return false


# --------------------------------------------------------------------------
# energy
# --------------------------------------------------------------------------

## Whether a machine may operate this tick.  ``consume`` false only asks
## whether it *could* run, which is what lets a machine check its power before
## committing ingredients to a craft.
func _machine_may_run(machine: Entity, proto: Dictionary, consume := true) -> bool:
	if Energy.is_burner(proto):
		if not _burner_available(machine):
			return false
		if consume:
			_consume_machine_energy(machine, proto)
			machine.state["ran"] = true
		return true
	if Energy.is_electric(proto):
		var satisfied := power.satisfaction_for(machine) > 0.0
		if satisfied and consume:
			machine.state["ran"] = true
		return satisfied
	if consume:
		machine.state["ran"] = true
	return true


# --------------------------------------------------------------------------
# logistics
# --------------------------------------------------------------------------

## Move items between logistic chests with robots, then let the roboports top
## their own buffers up.
func _update_logistics() -> void:
	# The technology tree can be swapped in after construction, so the bonus
	# set is kept in step here rather than at every call site.
	if research != null:
		logistics.modifiers = research.modifiers
	if character != null:
		character.research = research
		character.refresh_health_bonus()
	logistics.update()
	for port: Entity in live_of_type("roboport"):
		_machine_may_run(port, port.prototype())


# --------------------------------------------------------------------------
# enemy bases
# --------------------------------------------------------------------------

## Chunks nearer than this to the origin never hold a nest, so the player has
## somewhere to build before the biters notice.
const DEFAULT_ENEMY_SAFE_CHUNKS := 14
## Chance that a chunk past the safe ring holds a nest.
const ENEMY_BASE_CHANCE := 0.30

## Nests are laid down as land is generated, so they are already there when the
## player walks out — the way Factorio's autoplace works.
func _on_chunk_generated(coord: Vector2i) -> void:
	var from_start := coord - enemy_safe_center
	if from_start.x * from_start.x + from_start.y * from_start.y \
			< enemy_safe_chunks * enemy_safe_chunks:
		return
	if MapGenerator.hash01(coord, 0x8BAD) > ENEMY_BASE_CHANCE:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(coord) * 31 + Vector2i(7, 13))
	var centre := coord * GameWorld.CHUNK + Vector2i(GameWorld.CHUNK / 2,
		GameWorld.CHUNK / 2)
	var count := rng.randi_range(1, 3)
	var placed := 0
	for attempt in 24:
		if placed >= count:
			break
		var cell := centre + Vector2i(rng.randi_range(-12, 12), rng.randi_range(-12, 12))
		var tile := world.tile_at(cell)
		if world.generator._is_water(tile):
			continue
		var spawner := Entity.create("unit-spawner", "biter-spawner", cell, 0)
		if not world.place_entity(spawner):
			continue
		placed += 1
	if placed > 0:
		stats["nests"] = int(stats.get("nests", 0)) + placed


# --------------------------------------------------------------------------
# health and damage
# --------------------------------------------------------------------------

## Starting health of an entity, from its prototype.
static func max_health_of(proto: Dictionary) -> float:
	var value: Variant = proto.get("max_health")
	return float(value) if value != null else 100.0


## Apply a prototype's damage resistances.
##
## Factorio subtracts a flat ``decrease`` and then scales by ``percent``, so a
## big hit is only partly stopped by a percentage resistance.
static func after_resistances(proto: Dictionary, amount: float, damage_type: String) -> float:
	var resistances: Variant = proto.get("resistances", [])
	if resistances is Array:
		for entry: Variant in resistances:
			if not (entry is Dictionary):
				continue
			if str(entry.get("type", "")) != damage_type:
				continue
			var decrease := float(entry.get("decrease", 0.0))
			var percent := float(entry.get("percent", 0.0))
			return maxf(0.0, (amount - decrease) * (1.0 - percent / 100.0))
	return maxf(0.0, amount)


## Hurt an entity.  Returns true when it died.
func damage_entity(entity: Entity, amount: float, damage_type := "physical",
		attacker: Variant = null) -> bool:
	if entity == null or not world.entities.has(entity.origin):
		return false
	var dealt := after_resistances(entity.prototype(), amount, damage_type)
	var health := float(entity.state.get("health", max_health_of(entity.prototype())))
	health -= dealt
	entity.state["health"] = health
	stats["damage_dealt"] = float(stats.get("damage_dealt", 0.0)) + dealt
	if health <= 0.0:
		_destroy_entity(entity, attacker)
		return true
	return false


## Kill an entity: anything it held spills, and the world forgets it.
func _destroy_entity(entity: Entity, attacker: Variant = null) -> void:
	if not world.entities.has(entity.origin):
		return
	# Drop whatever the wreck was holding, as Factorio does.
	for key: String in InventoryLayout.for_entity(entity):
		var inventory := InventoryLayout.get_inventory(entity, key)
		if inventory == null:
			continue
		for slot: Variant in inventory.slots:
			if slot != null and int(slot.get("count", 0)) > 0:
				spilled.emit(entity.center(), str(slot["name"]), int(slot["count"]))
	entity_destroyed.emit(entity, attacker)
	world.remove_entity(entity)
	stats["destroyed"] = int(stats.get("destroyed", 0)) + 1


# --------------------------------------------------------------------------
# enemies
# --------------------------------------------------------------------------

## Spawn a biter or spitter near a nest.  Units live off the tile grid.
func spawn_unit(unit_name: String, position: Vector2) -> Dictionary:
	var proto := Prototypes.get_p("unit", unit_name)
	if proto.is_empty():
		return {}
	var unit := {
		"name": unit_name,
		"position": position,
		"direction": 8,
		"health": max_health_of(proto),
		"max_health": max_health_of(proto),
		"cooldown": 0,
		"target": null,
		"target_position": Vector2.ZERO,
		"spawner": null,
		"animation": 0.0,
		"moving": false,
		"target_scan": -9999,
	}
	units.append(unit)
	stats["units_spawned"] = int(stats.get("units_spawned", 0)) + 1
	return unit


func unit_prototype(unit: Dictionary) -> Dictionary:
	return Prototypes.get_p("unit", str(unit.get("name", "")))


## The evolution factor: how far the biters have come.
##
## Factorio grows it from elapsed time, pollution produced and nests killed.
## Time and pollution are modelled here; kills are not counted yet.
func _update_evolution() -> void:
	_elapsed_seconds += TICK_DELTA
	var from_time := _elapsed_seconds / 360000.0          # 0.1 after ten hours
	var from_pollution := _pollution_produced / 2500000.0  # 0.1 per 250k units
	evolution = clampf((from_time + from_pollution) * maxf(evolution_speed, 0.0),
		0.0, 1.0)


## Pick which unit a nest may spawn at the current evolution.
##
## ``result_units`` is a list of ``[name, [[evolution, weight], ...]]``; the
## weight is interpolated over the evolution factor, exactly as the prototype
## describes it.
static func choose_unit(proto: Dictionary, evolution_factor: float) -> String:
	var candidates: Variant = proto.get("result_units", [])
	if not (candidates is Array):
		return ""
	var best := ""
	var best_weight := 0.0
	var total := 0.0
	var weights: Array = []
	for entry: Variant in candidates:
		if not (entry is Array) or entry.size() < 2:
			continue
		var weight := _interpolate_evolution(entry[1], evolution_factor)
		total += weight
		weights.append({"name": str(entry[0]), "weight": weight})
	if total <= 0.0:
		return ""
	var roll := randf() * total
	for item: Dictionary in weights:
		roll -= float(item["weight"])
		if roll <= 0.0:
			best = str(item["name"])
			best_weight = float(item["weight"])
			break
	return best if best_weight > 0.0 else ""


static func _interpolate_evolution(table: Variant, evolution_factor: float) -> float:
	if not (table is Array) or (table as Array).is_empty():
		return 0.0
	var points: Array = table
	var previous: Variant = points[0]
	var next: Variant = points[points.size() - 1]
	for index in points.size():
		var point: Variant = points[index]
		if not (point is Array) or point.size() < 2:
			continue
		if float(point[0]) <= evolution_factor:
			previous = point
		if float(point[0]) >= evolution_factor:
			next = point
			break
	if previous == next:
		return float(previous[1])
	var span := float(next[0]) - float(previous[0])
	if span <= 0.0:
		return float(previous[1])
	var t := (evolution_factor - float(previous[0])) / span
	return lerpf(float(previous[1]), float(next[1]), t)


## Drop nests and units that ended up inside the start safe zone.  Chunks
## around the start can be generated while the factory anchor is being found,
## before the exact spawn (and therefore the safe centre) is known.
func enforce_start_safe_zone() -> void:
	var radius := float(maxi(enemy_safe_chunks, 0) * GameWorld.CHUNK)
	var centre := Vector2(enemy_safe_center * GameWorld.CHUNK) \
		+ Vector2(GameWorld.CHUNK, GameWorld.CHUNK) * 0.5
	for spawner: Entity in world.entities_of_type("unit-spawner"):
		var from_start := GameWorld.chunk_of(spawner.origin) - enemy_safe_center
		if from_start.x * from_start.x + from_start.y * from_start.y \
				< enemy_safe_chunks * enemy_safe_chunks:
			world.remove_entity(spawner)
	for unit: Dictionary in units.duplicate():
		if Vector2(unit.get("position", Vector2.ZERO)).distance_to(centre) < radius:
			units.erase(unit)


## Nests, biters and turrets, in that order.
func _update_enemies() -> void:
	_update_evolution()
	_update_spawners()
	_update_units()


## A nest soaks up pollution and turns it into biters.
func _update_spawners() -> void:
	# Count owned units once instead of walking the whole unit list for every
	# nest; this was O(nests × units) and became noticeable near a large
	# biter region even when the nests themselves were off-screen.
	var owned: Dictionary = {}
	for unit: Dictionary in units:
		var owner: Variant = unit.get("spawner")
		if owner is Entity:
			owned[owner] = int(owned.get(owner, 0)) + 1
	for spawner: Entity in live_of_type("unit-spawner"):
		var proto := spawner.prototype()
		var cooldown := int(spawner.state.get("spawn_cooldown", 0)) - 1
		if cooldown > 0:
			spawner.state["spawn_cooldown"] = cooldown
			continue

		# It has to have something to eat before it can grow anything.
		var absorption: Variant = proto.get("absorptions_per_second", {})
		var rate := 1.0
		if absorption is Dictionary:
			var pollution_entry: Variant = absorption.get("pollution", {})
			if pollution_entry is Dictionary:
				rate = float(pollution_entry.get("absolute", 0.0)) 					+ float(pollution_entry.get("proportional", 0.0)) 					* pollution.pollution_at(spawner.origin)
		var eaten := pollution.absorb(spawner.origin, rate * TICK_DELTA)
		if eaten <= 0.0 and int(owned.get(spawner, 0)) == 0:
			spawner.state["spawn_cooldown"] = 30
			continue

		var limit := int(proto.get("max_count_of_owned_units", 7))
		if int(owned.get(spawner, 0)) >= limit:
			spawner.state["spawn_cooldown"] = 60
			continue

		if units.size() >= MAX_ACTIVE_UNITS:
			spawner.state["spawn_cooldown"] = 120
			continue
		var unit_name := choose_unit(proto, evolution)
		if unit_name.is_empty():
			spawner.state["spawn_cooldown"] = 60
			continue
		var unit := spawn_unit(unit_name, spawner.center())
		unit["spawner"] = spawner
		owned[spawner] = int(owned.get(spawner, 0)) + 1
		var spawning_radius := float(proto.get("spawning_radius", 4.0))
		var angle := randf() * TAU
		unit["position"] = spawner.center() + Vector2(cos(angle), sin(angle)) 			* spawning_radius

		var window: Variant = proto.get("spawning_cooldown", [360, 150])
		if window is Array and (window as Array).size() >= 2:
			spawner.state["spawn_cooldown"] = randi_range(int(window[1]), int(window[0]))
		else:
			spawner.state["spawn_cooldown"] = 360
		stats["spawned"] = int(stats.get("spawned", 0)) + 1


func _owned_units(spawner: Entity) -> int:
	var count := 0
	for unit: Dictionary in units:
		if unit.get("spawner") == spawner:
			count += 1
	return count


## Walk every biter towards something worth biting, and bite it.
func _update_units() -> void:
	var dead: Array = []
	for unit: Dictionary in units:
		var proto := unit_prototype(unit)
		if proto.is_empty():
			dead.append(unit)
			continue
		var position := Vector2(unit["position"])
		# Units far outside the engineer's neighbourhood only need a fraction
		# of the AI ticks; this keeps a large biter region from spending the
		# frame budget on things nobody can see.
		if character != null and position.distance_to(character.position) > 80.0 \
				and tick % 5 != 0:
			continue
		var target_position := _unit_target_position(unit)
		var distance := position.distance_to(target_position)

		var attack := proto.get("attack_parameters", {})
		# A melee biter has to touch its target; a spitter fires from where it
		# stands, so its whole attack range counts.
		var reach := float(attack.get("range", 1.0)) if attack is Dictionary else 1.0
		if attack is Dictionary and str(attack.get("ammo_category", "")) == "melee":
			reach += 0.4
		var cooldown := int(unit.get("cooldown", 0))
		if cooldown > 0:
			unit["cooldown"] = cooldown - 1

		var step := float(proto.get("movement_speed", 0.2))
		if distance > reach + step:
			var heading := target_position - position
			if heading.length() > 0.001:
				var direction := heading.normalized()
				unit["direction"] = _direction_from_vector(direction)
				unit["position"] = position + direction * step
				unit["moving"] = true
				# The run sheet animates with distance covered, not with time.
				unit["animation"] = float(unit.get("animation", 0.0)) + 1.0
			continue

		unit["moving"] = false
		unit["position"] = position
		if cooldown > 0:
			continue
		if _unit_attacks(unit, proto):
			unit["cooldown"] = int(attack.get("cooldown", 35)) if attack is Dictionary else 35

	for unit: Dictionary in dead:
		units.erase(unit)
	_reap_units()


## Where a biter is heading, in tiles.
##
## The engineer comes first when close enough — that is what makes walking into
## a nest dangerous.  Otherwise biters go for the nearest player building, and
## with nothing built they follow the smog instead, which is what makes
## pollution the real trigger.
func _unit_target_position(unit: Dictionary) -> Vector2:
	var position := Vector2(unit["position"])
	var vision := float(unit_prototype(unit).get("vision_distance", 30.0))

	if character != null and character.is_alive():
		var to_engineer := character.position.distance_to(position)
		if to_engineer <= vision * 0.5:
			unit["targeting_player"] = true
			unit["target"] = null
			return character.position
	unit["targeting_player"] = false

	var target: Variant = unit.get("target")
	if target is Entity and world.entities.has((target as Entity).origin):
		var target_distance := (target as Entity).center().distance_to(position)
		# Do not chase a target that walked far outside the vision cone; clear
		# it and let the throttled scan below pick a fresh one.
		if target_distance <= vision * 2.0:
			return (target as Entity).center()
		unit["target"] = null

	# Looking for a building means walking every world entity.  Biters do not
	# need that at 60 Hz: re-scan three times a second and stand by the nest in
	# between.  Player proximity is still checked every tick above.
	if tick - int(unit.get("target_scan", -9999)) < 20:
		var spawner: Variant = unit.get("spawner")
		if spawner is Entity and world.entities.has((spawner as Entity).origin):
			return (spawner as Entity).center()
		return position
	unit["target_scan"] = tick

	var cell := Vector2i(int(floor(position.x)), int(floor(position.y)))
	var best: Entity = null
	var best_distance := vision
	for entity: Entity in world.entities.values():
		if entity.is_ghost():
			continue
		if not _is_player_building(entity):
			continue
		var distance := Vector2(entity.origin).distance_to(position)
		if distance < best_distance:
			best_distance = distance
			best = entity
	if best != null:
		unit["target"] = best
		return best.center()
	var smog := pollution.nearest_pollution(cell, 40)
	if smog != Vector2i(-9999, -9999):
		return Vector2(smog * Pollution.CHUNK_SIZE + Vector2i(16, 16))
	var spawner: Variant = unit.get("spawner")
	if spawner is Entity and world.entities.has((spawner as Entity).origin):
		return (spawner as Entity).center()
	return position


## Anything the biters consider theirs to break.
static func _is_player_building(entity: Entity) -> bool:
	var flags: Variant = entity.prototype().get("flags", [])
	if flags is Array and (flags as Array).has("placeable-enemy"):
		return false
	if entity.proto_type in ["unit", "unit-spawner", "turret", "tree", "simple-entity"]:
		return false
	if entity.proto_type in ["resource"]:
		return false
	return true


## One bite or spit, on whatever the biter was heading for.
func _unit_attacks(unit: Dictionary, proto: Dictionary) -> bool:
	var damage := _attack_damage(proto.get("attack_parameters", {}))
	if damage.is_empty():
		damage = {"amount": 5.0, "type": "physical"}
	var amount := float(damage["amount"])
	var damage_type := str(damage["type"])
	stats["bites"] = int(stats.get("bites", 0)) + 1

	if bool(unit.get("targeting_player", false)) and character != null:
		character.take_damage(amount, damage_type)
		stats["player_hits"] = int(stats.get("player_hits", 0)) + 1
		return true
	var target: Variant = unit.get("target")
	if target is Entity and world.entities.has((target as Entity).origin):
		damage_entity(target as Entity, amount, damage_type, unit)
		return true
	return true


static func _attack_damage(attack: Variant) -> Dictionary:
	if not (attack is Dictionary):
		return {}
	var found: Array = []
	_collect_damage(attack, found)
	return found[0] if not found.is_empty() else {}


static func _collect_damage(node: Variant, out: Array) -> void:
	if node is Dictionary:
		if str(node.get("type", "")) == "damage" and node.get("damage") is Dictionary:
			out.append(node["damage"])
		for key: String in node:
			_collect_damage(node[key], out)
	elif node is Array:
		for entry: Variant in node:
			_collect_damage(entry, out)


static func _direction_from_vector(vector: Vector2) -> int:
	var angle := atan2(vector.y, vector.x)
	# Factorio's direction 0 is north, increasing clockwise.
	var index := int(round((angle + PI * 0.5) / (PI / 8.0)))
	return posmod(index, 16)


## Take the dead out of the list.
func _reap_units() -> void:
	var alive: Array = []
	for unit: Dictionary in units:
		if float(unit.get("health", 0.0)) > 0.0:
			alive.append(unit)
		else:
			stats["units_killed"] = int(stats.get("units_killed", 0)) + 1
	units = alive


## Hurt a unit.  Returns true when it died.
func damage_unit(unit: Dictionary, amount: float, damage_type := "physical") -> bool:
	var proto := unit_prototype(unit)
	var dealt := after_resistances(proto, amount, damage_type)
	unit["health"] = float(unit.get("health", 0.0)) - dealt
	stats["damage_dealt"] = float(stats.get("damage_dealt", 0.0)) + dealt
	return float(unit["health"]) <= 0.0


# --------------------------------------------------------------------------
# turrets
# --------------------------------------------------------------------------

## Gun turrets track the closest biter in range and shoot on their own clock.
func _update_turrets() -> void:
	for turret: Entity in live_of_type("ammo-turret"):
		var proto := turret.prototype()
		var attack: Variant = proto.get("attack_parameters", {})
		if not (attack is Dictionary):
			continue
		var range_tiles := float(attack.get("range", 18.0))
		var cooldown := int(turret.state.get("cooldown", 0)) - 1
		turret.state["cooldown"] = maxi(0, cooldown)

		var target := _nearest_unit(turret.center(), range_tiles)
		if target.is_empty():
			turret.state["target"] = null
			continue
		turret.state["target"] = target
		var heading := Vector2(target["position"]) - turret.center()
		turret.state["aim"] = _direction_from_vector(heading)
		if cooldown > 0:
			continue

		var ammo := _take_turret_ammo(turret, str(attack.get("ammo_category", "bullet")))
		if ammo.is_empty():
			continue
		var damage := _attack_damage(ammo.get("ammo_type", ammo))
		if damage.is_empty():
			damage = {"amount": 5.0, "type": "physical"}
		# Turret attack research and bullet damage research both land here.
		var category := str(ammo.get("ammo_category", ""))
		var amount := float(damage["amount"])
		var shot_ticks := float(attack.get("cooldown", 6))
		var bonuses := research.modifiers if research != null else null
		if bonuses != null:
			amount *= bonuses.turret_damage_for(turret.name)
			amount *= bonuses.ammo_damage_for(category)
			shot_ticks /= maxf(0.1, bonuses.gun_speed_for(category))
		turret.state["cooldown"] = maxi(1, int(round(shot_ticks)))
		turret.state["shots"] = int(turret.state.get("shots", 0)) + 1
		stats["shots"] = int(stats.get("shots", 0)) + 1
		damage_unit(target, amount, str(damage["type"]))
		_reap_units()
		unit_hit.emit(target, amount)


func _nearest_unit(from: Vector2, radius: float) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := radius
	for unit: Dictionary in units:
		var distance := Vector2(unit["position"]).distance_to(from)
		if distance <= best_distance:
			best_distance = distance
			best = unit
	return best


## Pull one round out of a turret's magazine.
func _take_turret_ammo(turret: Entity, category: String) -> Dictionary:
	var inventory := InventoryLayout.get_inventory(turret, InventoryLayout.FUEL)
	if inventory == null:
		inventory = InventoryLayout.get_inventory(turret, InventoryLayout.OUTPUT)
	if inventory == null:
		return {}
	for slot: Variant in inventory.slots:
		if slot == null:
			continue
		var proto := Prototypes.get_p("ammo", str(slot["name"]))
		if proto.is_empty() or str(proto.get("ammo_category", "")) != category:
			continue
		inventory.extract(str(slot["name"]), 1)
		return proto
	return {}


# --------------------------------------------------------------------------
# pollution
# --------------------------------------------------------------------------

## Everything in the world that gives off pollution while it works.
##
## The rate comes from the prototype's ``energy_source.emissions_per_minute``,
## and only machines that actually ran this tick emit — an idle factory is a
## clean factory.
func _collect_emitters() -> Array:
	var emitters: Array = []
	for entity: Entity in world.entities.values():
		var proto := entity.prototype()
		if proto.is_empty():
			continue
		var source: Variant = proto.get("energy_source", {})
		if not (source is Dictionary):
			continue
		var per_minute: Variant = source.get("emissions_per_minute", {})
		if not (per_minute is Dictionary):
			continue
		var rate := float(per_minute.get("pollution", 0.0))
		if rate <= 0.0:
			continue
		# Burners emit while their fire is lit; electric machines only while
		# they have power to run.
		var active := bool(entity.state.get("ran", false))
		if Energy.is_burner(proto):
			active = float(entity.state.get("burn_energy", 0.0)) > 0.0
		if not active:
			continue
		emitters.append({"cell": entity.origin, "rate": rate})
	return emitters


## Run one tick of the smog, then clear the "ran" marks the machines left.
func _update_pollution() -> void:
	pollution.update(_collect_emitters())
	for entity: Entity in world.entities.values():
		if entity.state.get("ran", false):
			entity.state["ran"] = false


func _consume_machine_energy(machine: Entity, proto: Dictionary) -> void:
	if not Energy.is_burner(proto):
		return
	var usage := Energy.usage(proto) * TICK_DELTA
	machine.state["burn_energy"] = maxf(0.0,
		float(machine.state.get("burn_energy", 0.0)) - usage)


## Fraction of full speed a machine runs at.  Electric machines slow down
## during a brown-out instead of stopping, exactly like Factorio's.
func _satisfaction(machine: Entity, proto: Dictionary) -> float:
	if Energy.is_electric(proto):
		return power.satisfaction_for(machine)
	return 1.0


# --------------------------------------------------------------------------
# helpers used by the player and by tests
# --------------------------------------------------------------------------

## Give items to any entity's input side (used by tests and the debug tools).
func feed(entity: Entity, item_name: String, amount: int) -> int:
	var inventory := _primary_inventory(entity, item_name, true)
	if inventory == null:
		return amount
	return inventory.insert(item_name, amount)


func drain_output(entity: Entity, item_name := "", amount := 1000) -> Dictionary:
	var inventory := _primary_inventory(entity, item_name, false)
	if inventory == null:
		return {}
	return inventory.take_stack(item_name)


func summary() -> Dictionary:
	return {
		"tick": tick,
		"entities": world.entity_count(),
		"belts": stats["belts"],
		"belt_items": stats["belt_items"],
		"inserters": stats["inserters"],
		"mined": stats["mined"],
		"crafts": stats["crafts"],
		"power": power.stats(),
	}
