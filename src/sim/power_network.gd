class_name PowerNetwork
extends RefCounted
## Electric network: poles, generators and consumers.
##
## Factorio groups poles into networks by wire reach, then every machine
## inside a pole's supply area belongs to that network.  Each network balances
## production against demand and hands every consumer a *satisfaction* ratio
## in ``[0, 1]`` — machines simply run slower when power is short, which is
## what makes Factorio's brown-outs feel the way they do.

const TICK_DELTA := 1.0 / 60.0

var world: GameWorld
var _by_entity: Dictionary = {}       ## Entity -> Network
var _dirty := true

var total_generation := 0.0
var total_consumption := 0.0
var total_demand := 0.0
## Copper connections, as ``[pole_a, pole_b]`` pairs.  Rebuilt with the
## topology so the renderer can draw exactly the wires the network uses.
var links: Array = []

signal rebuilt


class Network:
	extends RefCounted
	var poles: Array = []
	var consumers: Array = []
	var generators: Array = []
	var accumulator_stored := 0.0

	func satisfaction() -> float:
		if consumers.is_empty():
			return 1.0
		return 1.0


func _init(world_: GameWorld) -> void:
	world = world_


func mark_dirty() -> void:
	_dirty = true


# --------------------------------------------------------------------------
# topology
# --------------------------------------------------------------------------

func _rebuild() -> void:
	_dirty = false
	_by_entity.clear()
	links.clear()
	total_generation = 0.0
	total_consumption = 0.0
	total_demand = 0.0

	var poles: Array = world.entities_of_type("electric-pole")
	# Union-find over poles that are within wire reach of each other.
	var parent: Dictionary = {}
	for pole: Entity in poles:
		parent[pole] = pole

	for i in poles.size():
		for j in range(i + 1, poles.size()):
			var a: Entity = poles[i]
			var b: Entity = poles[j]
			if _wired(a, b):
				_union(parent, a, b)
				links.append([a, b])

	var groups: Dictionary = {}
	for pole: Entity in poles:
		var root: Entity = _find(parent, pole)
		if not groups.has(root):
			groups[root] = Network.new()
		(groups[root] as Network).poles.append(pole)

	# Attach generators and consumers to the nearest covering pole network.
	var producers: Array = []
	for type_name: String in ["generator", "solar-panel", "accumulator"]:
		producers.append_array(world.entities_of_type(type_name))

	for entity: Entity in world.entities.values():
		if entity.is_ghost():
			continue
		if not _is_electric_consumer(entity):
			continue
		var network := _network_for_position(groups, entity.center())
		if network == null:
			continue
		network.consumers.append(entity)
		_by_entity[entity] = network

	for producer: Entity in producers:
		var network := _network_for_position(groups, producer.center())
		if network == null:
			continue
		network.generators.append(producer)
		_by_entity[producer] = network

	rebuilt.emit()


## World-space points of a slightly sagging copper wire between two anchors.
## Factorio's wires are catenary-like rather than straight lines; a shallow
## parabola is enough at this camera distance and keeps the draw list cheap.
static func wire_curve(from: Vector2, to: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	var distance := from.distance_to(to)
	var steps := clampi(int(distance / 24.0), 3, 24)
	var sag := minf(distance * 0.035, 18.0)
	for i in steps + 1:
		var t := float(i) / float(steps)
		points.append(from.lerp(to, t) + Vector2(0.0, sag * 4.0 * t * (1.0 - t)))
	return points


## Where a power pole's copper wire attaches, in world pixels.
##
## Connection points are already arranged around the top of the pole.  They
## must not be rotated with the entity: a small pole facing west would turn its
## top attachment into a point beside the base, which is what made the wires
## appear to run along the bottom of the poles.  Pick the highest point so all
## wires visibly attach at the pole top.
static func wire_anchor(entity: Entity) -> Vector2:
	var proto := entity.prototype()
	var points: Variant = proto.get("connection_points", [])
	var local := Vector2(0, -2.2)
	var best_y := INF
	if points is Array:
		for point: Variant in points:
			if not (point is Dictionary):
				continue
			var wire: Variant = (point as Dictionary).get("wire", {})
			if not (wire is Dictionary):
				continue
			var copper: Variant = (wire as Dictionary).get("copper", null)
			if copper == null:
				continue
			var candidate := FactorioAssets.parse_vector(copper)
			if candidate.y < best_y:
				best_y = candidate.y
				local = candidate
	return entity.center() * 32.0 + local * 32.0


func _wired(a: Entity, b: Entity) -> bool:
	var a_proto := a.prototype()
	var b_proto := b.prototype()
	var reach_a := float(a_proto.get("maximum_wire_distance", 7.5))
	var reach_b := float(b_proto.get("maximum_wire_distance", 7.5))
	# Distance between the pole bodies, not their top-left origins: a big pole
	# and a substation have different footprints.
	var distance := a.center().distance_to(b.center())
	return distance <= maxf(reach_a, reach_b) + 0.01


## Copper connections, rebuilding the topology first if a pole was added or
## removed since the last simulation tick.
func connections() -> Array:
	if _dirty:
		_rebuild()
	return links


func _find(parent: Dictionary, node: Entity) -> Entity:
	var root: Entity = node
	while parent[root] != root:
		root = parent[root]
	# Path compression.
	var walk: Entity = node
	while parent[walk] != root:
		var next: Entity = parent[walk]
		parent[walk] = root
		walk = next
	return root


func _union(parent: Dictionary, a: Entity, b: Entity) -> void:
	var root_a := _find(parent, a)
	var root_b := _find(parent, b)
	if root_a != root_b:
		parent[root_b] = root_a


func _network_for_position(groups: Dictionary, position: Vector2) -> Network:
	for key: Variant in groups:
		var network: Network = groups[key]
		for pole: Entity in network.poles:
			var area := float(pole.prototype().get("supply_area_distance", 2.5))
			# supply_area_distance is half the side of the square area.
			if absf(position.x - pole.center().x) <= area + 0.5 \
					and absf(position.y - pole.center().y) <= area + 0.5:
				return network
	return null


static func _is_electric_consumer(entity: Entity) -> bool:
	var proto := entity.prototype()
	if proto.is_empty():
		return false
	if not Energy.is_electric(proto):
		return false
	return Energy.usage(proto) > 0.0 or Energy.drain(proto) > 0.0


# --------------------------------------------------------------------------
# balancing
# --------------------------------------------------------------------------

## Distribute this tick's energy and return the satisfaction per consumer.
func update() -> void:
	if _dirty:
		_rebuild()
	total_generation = 0.0
	total_consumption = 0.0
	total_demand = 0.0

	var networks: Array = []
	for key: Variant in _by_entity:
		var network: Variant = _by_entity[key]
		if network != null and not networks.has(network):
			networks.append(network)

	for network: Network in networks:
		_balance(network)


func _balance(network: Network) -> void:
	var supply := 0.0
	for generator: Entity in network.generators:
		supply += _generate(generator)

	var demand := 0.0
	for consumer: Entity in network.consumers:
		var proto := consumer.prototype()
		demand += Energy.usage(proto) + Energy.drain(proto)

	total_generation += supply
	total_demand += demand

	if demand <= 0.0:
		return
	var ratio := clampf(supply / demand, 0.0, 1.0)
	total_consumption += demand * ratio

	for consumer: Entity in network.consumers:
		consumer.state["satisfaction"] = ratio


## Instantaneous output of one generator, in watts.
func _generate(generator: Entity) -> float:
	var proto := generator.prototype()
	match str(proto.get("type", "")):
		"solar-panel":
			# Factorio's solar panels peak at their nominal output; treat day
			# as constant until the day/night cycle lands.
			return Energy.parse(proto.get("production"), 0.0)
		"accumulator":
			var buffer := float(generator.state.get("charge", 0.0))
			if buffer > 0.0:
				var output := minf(buffer / TICK_DELTA,
					Energy.parse(proto.get("energy_source", {}).get("buffer_capacity"), 0.0) / 60.0)
				generator.state["charge"] = maxf(0.0, buffer - output * TICK_DELTA)
				return output
			return 0.0
		"generator":
			# Steam engines burn the steam a boiler produced; until fluids are
			# simulated they run whenever they have been given fuel indirectly.
			var available := float(generator.state.get("available_power", -1.0))
			if available < 0.0:
				return Energy.parse(proto.get("energy_source", {}).get("effectivity"), 1.0) \
					* _max_steam_output(proto)
			return available
	return 0.0


static func _max_steam_output(proto: Dictionary) -> float:
	# Steam engine: energy_source.burner? 2.0 exposes it as
	# ``max_energy_production`` in the fluid energy source.
	var source: Variant = proto.get("energy_source", {})
	if source is Dictionary:
		var explicit: Variant = source.get("max_energy_production")
		if explicit != null:
			return Energy.parse(explicit, 0.0)
	return Energy.parse(proto.get("energy_production"), 900000.0)


func satisfaction_for(entity: Entity) -> float:
	var network := _by_entity.get(entity)
	if network == null:
		return 0.0
	if (network as Network).consumers.is_empty():
		return 1.0
	return float(entity.state.get("satisfaction", 1.0))


func is_powered(entity: Entity) -> bool:
	return _by_entity.has(entity)


func stats() -> Dictionary:
	var distinct: Array = []
	for key: Variant in _by_entity:
		var network: Variant = _by_entity[key]
		if network != null and not distinct.has(network):
			distinct.append(network)
	return {
		"networks": distinct.size(),
		"powered_entities": _by_entity.size(),
		"generation": total_generation,
		"demand": total_demand,
	}
