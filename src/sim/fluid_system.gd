class_name FluidSystem
extends RefCounted
## Pipes, tanks and machine fluid boxes.
##
## Factorio 2.0 groups connected fluid boxes into a *segment*: fluid inside a
## segment equalises immediately, so the interesting constraints are the
## machines at either end, not the pipes.  This reproduces that model — the
## pipes are only a connectivity graph and the contents level out every tick.
##
## Connectivity comes from the prototypes' own ``pipe_connections``: each entry
## names a tile offset and a direction, so a boiler really does only accept
## water from its west and east faces and only emit steam from the north.

## ``fluid_box`` / ``output_fluid_box`` names for the single-box layout.
const PRIMARY := "fluid_box"
const SECONDARY := "output_fluid_box"

var world: GameWorld

## Networks, rebuilt whenever the world's entities change.
var _networks: Array = []
## "entity id|box name" -> index into ``_networks``.
var _network_of: Dictionary = {}
var _dirty := true
var _network_builds := 0


func _init(world_: GameWorld) -> void:
	world = world_


func mark_dirty() -> void:
	_dirty = true


func stats() -> Dictionary:
	return {"networks": _networks.size(), "builds": _network_builds}


# --------------------------------------------------------------------------
# fluid box descriptors
# --------------------------------------------------------------------------

## Every fluid box an entity has, in prototype order.
##
## Returns ``[{ name, index, volume, filter, production_type, connections }]``.
static func box_specs(entity: Entity) -> Array:
	var proto := entity.prototype()
	var out: Array = []
	if proto.has("fluid_box"):
		out.append(_spec(proto["fluid_box"], PRIMARY, -1))
	if proto.has("output_fluid_box"):
		out.append(_spec(proto["output_fluid_box"], SECONDARY, -1))
	var many: Variant = proto.get("fluid_boxes")
	if many is Array:
		for i in many.size():
			out.append(_spec(many[i], "fluid_box_%d" % i, i))
	return out


static func _spec(box: Variant, name: String, index: int) -> Dictionary:
	if not (box is Dictionary):
		return {"name": name, "index": index, "volume": 100.0, "filter": "",
			"production_type": "", "connections": []}
	return {
		"name": name,
		"index": index,
		"volume": maxf(1.0, float(box.get("volume", 100.0))),
		"filter": str(box.get("filter", "")),
		"production_type": str(box.get("production_type", "")),
		"connections": box.get("pipe_connections", []),
	}


static func spec_of(entity: Entity, box_name: String) -> Dictionary:
	for spec: Dictionary in box_specs(entity):
		if str(spec["name"]) == box_name:
			return spec
	return {}


## Whether an entity takes part in the fluid system at all.
static func has_fluid(entity: Entity) -> bool:
	return not box_specs(entity).is_empty()


# --------------------------------------------------------------------------
# contents (stored per box, so rebuilding networks never loses fluid)
# --------------------------------------------------------------------------

func _contents(entity: Entity) -> Dictionary:
	var store: Variant = entity.state.get("fluids")
	if store is Dictionary:
		return store
	var made: Dictionary = {}
	entity.state["fluids"] = made
	return made


## ``{ name, amount, temperature }`` currently inside one box.
func content(entity: Entity, box_name: String) -> Dictionary:
	var store := _contents(entity)
	var entry: Variant = store.get(box_name)
	if entry is Dictionary:
		return entry
	var made := {"name": "", "amount": 0.0, "temperature": 0.0}
	store[box_name] = made
	return made


func amount_in(entity: Entity, box_name: String) -> float:
	return float(content(entity, box_name)["amount"])


func fluid_in(entity: Entity, box_name: String) -> String:
	return str(content(entity, box_name)["name"])


func temperature_in(entity: Entity, box_name: String) -> float:
	return float(content(entity, box_name)["temperature"])


## Note: ``_set`` is reserved by Object, hence ``_store``.
func _store(entity: Entity, box_name: String, fluid: String, amount: float,
		temperature: float) -> void:
	var entry := content(entity, box_name)
	entry["name"] = fluid if amount > 0.0 else ""
	entry["amount"] = maxf(0.0, amount)
	entry["temperature"] = temperature


# --------------------------------------------------------------------------
# networks
# --------------------------------------------------------------------------

func rebuild() -> void:
	_dirty = false
	_network_builds += 1
	_networks.clear()
	_network_of.clear()

	# Every box in the world, with its connections resolved to neighbour cells.
	var boxes: Array = []
	for entity: Entity in world.entities.values():
		if entity.is_ghost():
			continue
		var specs := box_specs(entity)
		if specs.is_empty():
			continue
		for spec: Dictionary in specs:
			boxes.append({
				"entity": entity,
				"spec": spec,
				"key": _key(entity, str(spec["name"])),
			})
	if boxes.is_empty():
		return

	var parent: Dictionary = {}
	for box: Dictionary in boxes:
		parent[box["key"]] = box["key"]
	var by_key: Dictionary = {}
	for box: Dictionary in boxes:
		by_key[box["key"]] = box

	# Join boxes whose connections point at each other.  Boxes on the same
	# entity never join — a boiler's water side and steam side are separate
	# networks even though both touch the same neighbours.
	for box: Dictionary in boxes:
		var entity: Entity = box["entity"]
		for target: Dictionary in _neighbours(entity, box["spec"]):
			var other: Entity = target["entity"]
			if other == entity:
				continue
			for other_spec: Dictionary in box_specs(other):
				if not boxes_linked(world, entity, box["spec"], other, other_spec):
					continue
				var other_key := _key(other, str(other_spec["name"]))
				if parent.has(other_key):
					_union(parent, str(box["key"]), other_key)

	var groups: Dictionary = {}
	for box: Dictionary in boxes:
		var root := _find(parent, str(box["key"]))
		if not groups.has(root):
			groups[root] = []
		(groups[root] as Array).append(box)

	for root: Variant in groups:
		var members: Array = groups[root]
		var index := _networks.size()
		var capacity := 0.0
		for box: Dictionary in members:
			capacity += float((box["spec"] as Dictionary)["volume"])
			_network_of[str(box["key"])] = index
		_networks.append({"members": members, "capacity": capacity})


static func _key(entity: Entity, box_name: String) -> String:
	return "%d|%s" % [entity.get_instance_id(), box_name]


## Entities reachable through one fluid box's pipe connections.
func _neighbours(entity: Entity, spec: Dictionary) -> Array:
	return connection_targets(world, entity, spec)


## Tiles a fluid box's ``pipe_connections`` reach into.
static func connection_targets(world: GameWorld, entity: Entity,
		spec: Dictionary) -> Array:
	var out: Array = []
	for connection: Variant in spec.get("connections", []):
		if not (connection is Dictionary):
			continue
		# Most boxes give one ``position``; a pumpjack lists several in
		# ``positions``.
		var locals: Array = []
		if connection.has("positions"):
			locals = connection["positions"]
		elif connection.has("position"):
			locals = [connection["position"]]
		# Pipe connections are in the entity's local frame.  Every rotated
		# boiler, turbine, pump or machine turns its ports with it; leaving
		# this direction unrotated made a rotated turbine point north/south
		# while its pipes were actually east/west.
		var direction := posmod(int(connection.get("direction", 0)) \
			+ entity.direction, 16)
		for entry: Variant in locals:
			var local := FactorioAssets.parse_vector(entry)
			var position := entity.center() \
				+ Simulation.rotate_local(local, entity.direction)
			var cell := Vector2i(int(floor(position.x)), int(floor(position.y)))
			var neighbour := cell + BeltSim.dir_vector(direction)
			var other := world.entity_at(neighbour)
			if other != null and other != entity:
				out.append({"entity": other, "cell": neighbour})
	return out


## Whether two *specific* boxes are joined.
##
## Both sides have to point at each other: a boiler's steam port and its water
## port are different boxes on the same entity, and only the matching pair may
## end up in one network.
static func boxes_linked(world: GameWorld, a: Entity, spec_a: Dictionary,
		b: Entity, spec_b: Dictionary) -> bool:
	var towards_b := false
	for target: Dictionary in connection_targets(world, a, spec_a):
		if target["entity"] == b:
			towards_b = true
			break
	if not towards_b:
		return false
	for target: Dictionary in connection_targets(world, b, spec_b):
		if target["entity"] == a:
			return true
	return false


## Whether two entities share any fluid connection at all.  Used by pipe
## rendering, so a pipe draws a stub exactly where it can carry fluid.
static func connects(world: GameWorld, a: Entity, b: Entity) -> bool:
	for spec_a: Dictionary in box_specs(a):
		for spec_b: Dictionary in box_specs(b):
			if boxes_linked(world, a, spec_a, b, spec_b):
				return true
	return false


func _find(parent: Dictionary, key: String) -> String:
	var root := key
	while parent[root] != root:
		root = parent[root]
	var walk := key
	while parent[walk] != root:
		var next: String = parent[walk]
		parent[walk] = root
		walk = next
	return root


func _union(parent: Dictionary, a: String, b: String) -> void:
	var root_a := _find(parent, a)
	var root_b := _find(parent, b)
	if root_a != root_b:
		parent[root_b] = root_a


func _network_index(entity: Entity, box_name: String) -> int:
	if _dirty:
		rebuild()
	return int(_network_of.get(_key(entity, box_name), -1))


func network_size(entity: Entity, box_name: String) -> int:
	var index := _network_index(entity, box_name)
	if index < 0:
		return 0
	return (_networks[index]["members"] as Array).size()


# --------------------------------------------------------------------------
# aggregate view of one network
# --------------------------------------------------------------------------

## ``{ fluid, amount, capacity, temperature }`` for the network a box is in.
func aggregate(entity: Entity, box_name: String) -> Dictionary:
	var index := _network_index(entity, box_name)
	if index < 0:
		return {"fluid": "", "amount": 0.0, "capacity": 0.0, "temperature": 0.0}
	return _aggregate(index)


func _aggregate(index: int) -> Dictionary:
	var members: Array = _networks[index]["members"]
	var fluid := ""
	var best := 0.0
	var amount := 0.0
	var weighted := 0.0
	for box: Dictionary in members:
		var entry := content(box["entity"], str((box["spec"] as Dictionary)["name"]))
		var entry_amount := float(entry["amount"])
		if entry_amount <= 0.0:
			continue
		amount += entry_amount
		weighted += entry_amount * float(entry["temperature"])
		if entry_amount > best:
			best = entry_amount
			fluid = str(entry["name"])
	return {
		"fluid": fluid,
		"amount": amount,
		"capacity": float(_networks[index]["capacity"]),
		"temperature": weighted / amount if amount > 0.0 else 0.0,
	}


# --------------------------------------------------------------------------
# transfer
# --------------------------------------------------------------------------

## Put fluid into a box's network.  Returns how much was accepted.
func add(entity: Entity, box_name: String, fluid: String,
		amount: float, temperature := 0.0) -> float:
	if amount <= 0.0 or fluid.is_empty():
		return 0.0
	var index := _network_index(entity, box_name)
	if index < 0:
		return 0.0
	var spec := spec_of(entity, box_name)
	if not str(spec.get("filter", "")).is_empty() \
			and str(spec["filter"]) != fluid:
		return 0.0

	var state := _aggregate(index)
	if not str(state["fluid"]).is_empty() and str(state["fluid"]) != fluid:
		return 0.0

	var space: float = maxf(0.0, float(state["capacity"]) - float(state["amount"]))
	var accepted: float = minf(amount, space)
	if accepted <= 0.0:
		return 0.0
	_distribute(index, fluid, accepted, temperature)
	return accepted


## Take fluid out of a box's network.  Returns how much was actually taken.
func take(entity: Entity, box_name: String, fluid: String, amount: float) -> float:
	if amount <= 0.0:
		return 0.0
	var index := _network_index(entity, box_name)
	if index < 0:
		return 0.0
	var state := _aggregate(index)
	if str(state["fluid"]) != fluid:
		return 0.0
	var taken: float = minf(amount, float(state["amount"]))
	if taken <= 0.0:
		return 0.0
	_withdraw(index, fluid, taken)
	return taken


## Spread ``amount`` of fluid over the boxes of a network, filling evenly.
func _distribute(index: int, fluid: String, amount: float, temperature: float) -> void:
	var members: Array = _networks[index]["members"]
	var remaining := amount
	# Several passes so a box that fills up pushes the rest onwards.
	for _pass in 4:
		var space := 0.0
		for box: Dictionary in members:
			var spec: Dictionary = box["spec"]
			var entry := content(box["entity"], str(spec["name"]))
			if not str(entry["name"]).is_empty() and str(entry["name"]) != fluid:
				continue
			space += maxf(0.0, float(spec["volume"]) - float(entry["amount"]))
		if space <= 0.0 or remaining <= 0.0:
			break
		var share := minf(remaining, space)
		var moved := 0.0
		for box: Dictionary in members:
			var spec2: Dictionary = box["spec"]
			var entry2 := content(box["entity"], str(spec2["name"]))
			if not str(entry2["name"]).is_empty() and str(entry2["name"]) != fluid:
				continue
			var room: float = maxf(0.0, float(spec2["volume"]) - float(entry2["amount"]))
			if room <= 0.0:
				continue
			var piece: float = share * (room / space)
			var previous := float(entry2["amount"])
			var blended := temperature
			if previous > 0.0 and float(entry2["temperature"]) > 0.0:
				blended = (float(entry2["temperature"]) * previous
					+ temperature * piece) / maxf(previous + piece, 1e-6)
			_store(box["entity"], str(spec2["name"]), fluid, previous + piece, blended)
			moved += piece
		remaining -= moved
		if moved <= 0.0:
			break


func _withdraw(index: int, fluid: String, amount: float) -> void:
	var members: Array = _networks[index]["members"]
	var available := 0.0
	for box: Dictionary in members:
		var entry := content(box["entity"], str((box["spec"] as Dictionary)["name"]))
		if str(entry["name"]) == fluid:
			available += float(entry["amount"])
	if available <= 0.0:
		return
	var fraction: float = minf(1.0, amount / available)
	for box: Dictionary in members:
		var spec: Dictionary = box["spec"]
		var entry2 := content(box["entity"], str(spec["name"]))
		if str(entry2["name"]) != fluid:
			continue
		var left := float(entry2["amount"]) * (1.0 - fraction)
		if left < 1e-4:
			_store(box["entity"], str(spec["name"]), "", 0.0, 0.0)
		else:
			_store(box["entity"], str(spec["name"]), fluid, left, float(entry2["temperature"]))


# --------------------------------------------------------------------------
# tick
# --------------------------------------------------------------------------

## Level the fluid inside each network so the segment behaves as one tank.
func update() -> void:
	if _dirty:
		rebuild()
	for index in _networks.size():
		_equalise(index)


func _equalise(index: int) -> void:
	var state := _aggregate(index)
	var fluid := str(state["fluid"])
	var amount := float(state["amount"])
	if fluid.is_empty() or amount <= 0.0:
		return
	var capacity: float = maxf(1.0, float(state["capacity"]))
	var members: Array = _networks[index]["members"]

	# Any box already holding a different fluid means the segment is mixed;
	# leave it alone rather than silently merging two fluids.
	for box: Dictionary in members:
		var entry := content(box["entity"], str((box["spec"] as Dictionary)["name"]))
		if float(entry["amount"]) > 0.0 and str(entry["name"]) != fluid:
			return

	var level := amount / capacity
	var temperature := float(state["temperature"])
	for box: Dictionary in members:
		var spec: Dictionary = box["spec"]
		var target: float = minf(float(spec["volume"]), float(spec["volume"]) * level)
		_store(box["entity"], str(spec["name"]), fluid, target, temperature)


## Total fluid of a kind anywhere in the world, for the debug overlay.
func total_of(fluid: String) -> float:
	var sum := 0.0
	if _dirty:
		rebuild()
	for index in _networks.size():
		var state := _aggregate(index)
		if str(state["fluid"]) == fluid:
			sum += float(state["amount"])
	return sum
