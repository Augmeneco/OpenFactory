class_name CircuitNetwork
extends RefCounted
## Red and green wires, and the signals that run along them.
##
## Factorio's model is simple once the pieces are separated: every device on a
## wire *reads* the sum of what every device on that wire *writes*, and there is
## a one-tick delay between writing and reading.  That delay is what makes a
## combinator loop settle into a counter instead of spinning forever, so it is
## kept rather than optimised away.
##
## Wires are stored on both of the entities they join, so removing a machine
## takes its wires with it.

const RED := "red"
const GREEN := "green"
const COLOURS := [RED, GREEN]

## The wildcard signals, which mean rather more than their names suggest.
const EACH := "signal-each"
const EVERYTHING := "signal-everything"
const ANYTHING := "signal-anything"

## Every arithmetic operation a combinator offers.
const OPERATIONS := ["+", "-", "*", "/", "%", "^", "<<", ">>", "AND", "OR",
	"XOR"]
const COMPARISONS := [">", "<", "=", ">=", "<=", "!="]

var world: GameWorld
## The fluid service, so a tank can report what is inside it.
var fluids: FluidSystem
## colour -> Array of { members: Array[Entity], signals: Dictionary }
var networks: Dictionary = {RED: [], GREEN: []}
var dirty := true
var _tick := 0
## What each device saw on its wires at the end of the last tick, keyed by
## cell.  Everything a device writes is computed from this and never from a
## fresh reading, which is what stops a pair of combinators recursing forever
## and gives every device Factorio's one-tick delay.
var _inputs: Dictionary = {}


func _init(world_: GameWorld) -> void:
	world = world_


func mark_dirty() -> void:
	dirty = true


func stats() -> Dictionary:
	# Reading the figures must not hand back yesterday's topology.
	if dirty:
		_rebuild()
	var red := 0
	var green := 0
	for network: Dictionary in networks[RED]:
		red += (network["members"] as Array).size()
	for network: Dictionary in networks[GREEN]:
		green += (network["members"] as Array).size()
	return {"red_networks": (networks[RED] as Array).size(),
		"green_networks": (networks[GREEN] as Array).size(),
		"red_members": red, "green_members": green,
		"wires": wire_count()}


func wire_count() -> int:
	var total := 0
	for entity: Entity in world.entities.values():
		total += (entity.state.get("wires", []) as Array).size()
	return total / 2


# --------------------------------------------------------------------------
# wires
# --------------------------------------------------------------------------

static func wires_of(entity: Entity) -> Array:
	# The stored array is handed back, not a copy: a fresh `[]` default is
	# still an Array, so testing the type alone would append to a throwaway
	# and every wire would vanish.
	if not entity.state.has("wires") or not (entity.state["wires"] is Array):
		entity.state["wires"] = []
	return entity.state["wires"]


## Join two entities with a wire, once.  Both ends remember it.
##
## Named `add_wire` rather than `connect`, which Object already owns.
func add_wire(a: Entity, b: Entity, colour := RED) -> bool:
	# A device wired to itself is allowed: it is how a counter is built, and
	# the wire is drawn like any other.
	if a == null or b == null:
		return false
	if not can_wire(a) or not can_wire(b):
		return false
	var distance := a.center().distance_to(b.center())
	var limit := minf(wire_reach(a), wire_reach(b))
	if distance > limit:
		return false
	if has_wire(a, b, colour):
		return false
	wires_of(a).append({"to": [b.origin.x, b.origin.y], "colour": colour})
	wires_of(b).append({"to": [a.origin.x, a.origin.y], "colour": colour})
	mark_dirty()
	return true


func has_wire(a: Entity, b: Entity, colour := "") -> bool:
	for wire: Variant in wires_of(a):
		if not (wire is Dictionary):
			continue
		var entry: Dictionary = wire
		if colour != "" and str(entry.get("colour", RED)) != colour:
			continue
		if _cell_of(entry) == b.origin:
			return true
	return false


static func _cell_of(wire: Dictionary) -> Vector2i:
	var to: Variant = wire.get("to", null)
	if to is Array and (to as Array).size() >= 2:
		return Vector2i(int(to[0]), int(to[1]))
	return Vector2i(-1, -1)


## Every entity this one is wired to, with the colour of each wire.
func neighbours(entity: Entity) -> Array:
	var out: Array = []
	for wire: Variant in wires_of(entity):
		var cell := _cell_of(wire)
		var other := world.entity_at(cell)
		if other != null:
			out.append({"entity": other,
				"colour": str((wire as Dictionary).get("colour", RED))})
	return out


func disconnect_all(entity: Entity) -> void:
	for entry: Dictionary in neighbours(entity):
		_wire_remove(entry["entity"], entity.origin)
	entity.state["wires"] = []
	mark_dirty()


static func _wire_remove(entity: Entity, cell: Vector2i) -> void:
	var kept: Array = []
	for wire: Variant in wires_of(entity):
		if _cell_of(wire) != cell:
			kept.append(wire)
	entity.state["wires"] = kept


## Factorio reaches 30 tiles by default, and the wire is measured centre to
## centre.
static func wire_reach(entity: Entity) -> float:
	return float(entity.prototype().get("circuit_wire_max_distance", 30.0))


## Whether a machine can take a wire at all.
static func can_wire(entity: Entity) -> bool:
	if entity == null or entity.is_ghost():
		return false
	var proto := entity.prototype()
	if proto.is_empty():
		return false
	if proto.has("circuit_wire_max_distance"):
		return true
	# Chests, tanks, belts, inserters and machines all connect in Factorio even
	# where the prototype leaves the field out.
	return entity.proto_type in WIREABLE


const WIREABLE := ["constant-combinator", "arithmetic-combinator",
	"decider-combinator", "programmable-speaker", "electric-pole",
	"container", "logistic-container", "storage-tank", "inserter",
	"transport-belt", "underground-belt", "splitter", "mining-drill",
	"furnace", "assembling-machine", "lab", "roboport", "accumulator",
	"solar-panel", "generator", "boiler", "ammo-turret", "electric-turret",
	"artillery-turret", "radar", "pump", "offshore-pump", "gate", "reactor",
	"rocket-silo", "train-stop", "wall"]


# --------------------------------------------------------------------------
# networks
# --------------------------------------------------------------------------

func _rebuild() -> void:
	dirty = false
	for colour: String in COLOURS:
		networks[colour] = _groups_for(colour)


## One entry per connected group of devices on a colour of wire.
func _groups_for(colour: String) -> Array:
	var parent: Dictionary = {}
	for entity: Entity in world.entities.values():
		if entity.is_ghost() or not can_wire(entity):
			continue
		# Only devices actually on this colour belong to this colour's
		# networks.  Taking every wired device would leave each one that has
		# no wire of this colour sitting in a network of its own.
		var attached := false
		for wire: Variant in wires_of(entity):
			if wire is Dictionary \
					and str((wire as Dictionary).get("colour", RED)) == colour:
				attached = true
				break
		if not attached:
			continue
		parent[entity] = entity
	for entity: Entity in parent.keys():
		for entry: Dictionary in neighbours(entity):
			if entry["colour"] != colour:
				continue
			var other: Entity = entry["entity"]
			if parent.has(other):
				_union(parent, entity, other)

	var groups: Dictionary = {}
	for entity: Entity in parent.keys():
		var root: Entity = _find(parent, entity)
		if not groups.has(root):
			groups[root] = {"members": [], "signals": {}}
		(groups[root]["members"] as Array).append(entity)
	var out: Array = []
	for key: Entity in groups:
		out.append(groups[key])
	return out


func _find(parent: Dictionary, node: Entity) -> Entity:
	var root: Entity = node
	while parent[root] != root:
		root = parent[root]
	# Path compression, so a long chain does not become a walk each rebuild.
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


# --------------------------------------------------------------------------
# signals
# --------------------------------------------------------------------------

## What a device reads: the sum of its wires, as at the end of the last tick.
func input_for(entity: Entity, colour: String) -> Dictionary:
	var seen: Variant = _inputs.get(entity.origin, {})
	if not (seen is Dictionary):
		return {}
	return (seen as Dictionary).get(colour, {})


## Everything on a device's wire, including what it writes itself.
func network_signals(entity: Entity, colour: String) -> Dictionary:
	for network: Dictionary in networks[colour]:
		if (network["members"] as Array).has(entity):
			return network["signals"]
	return {}


## The wire colours a device is attached to.
func colours_of(entity: Entity) -> Array:
	var out: Array = []
	for colour: String in COLOURS:
		for network: Dictionary in networks[colour]:
			if (network["members"] as Array).has(entity):
				out.append(colour)
				break
	return out


## What a device writes onto the wire, before the tick's sum is taken.
func output_of(entity: Entity) -> Dictionary:
	match entity.proto_type:
		"constant-combinator":
			var fixed: Variant = entity.state.get("signals", {})
			return _clean(fixed if fixed is Dictionary else {})
		"arithmetic-combinator":
			return _arithmetic_output(entity)
		"decider-combinator":
			return _decider_output(entity)
	if not read_contents_enabled(entity):
		return {}
	return _contents_of(entity)


## A device's own contents, as signals, when it is set to report them.
func _contents_of(entity: Entity) -> Dictionary:
	var out: Dictionary = {}
	for key: String in [InventoryLayout.OUTPUT, InventoryLayout.INPUT,
			InventoryLayout.FUEL, InventoryLayout.STORAGE]:
		var inventory := InventoryLayout.get_inventory(entity, key)
		if inventory == null:
			continue
		for slot: Variant in inventory.slots:
			if slot == null:
				continue
			var name := str((slot as Dictionary)["name"])
			out[name] = int(out.get(name, 0)) + int((slot as Dictionary)["count"])
	if fluids != null:
		for box: Dictionary in FluidSystem.box_specs(entity):
			var state := fluids.aggregate(entity, str(box["name"]))
			var fluid := str(state.get("fluid", ""))
			if not fluid.is_empty():
				out[fluid] = int(out.get(fluid, 0)) \
					+ int(floor(float(state["amount"])))
	return _clean(out)


## The two modes a chest, tank or machine can report in.
static func read_contents_enabled(entity: Entity) -> bool:
	return bool(entity.state.get("read_contents", false))


static func read_hand_enabled(entity: Entity) -> bool:
	return bool(entity.state.get("read_hand", false))


static func _clean(signals: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for name: Variant in signals:
		var value := int(signals[name])
		if value != 0:
			out[str(name)] = value
	return out


# --------------------------------------------------------------------------
# combinators
# --------------------------------------------------------------------------

## One input signal's value, resolving the virtual names as Factorio does.
func _signal_value(input: Dictionary, name: String) -> int:
	if name == EVERYTHING or name == ANYTHING:
		return 0
	return int(input.get(name, 0))


## The arithmetic combinator: one operation, written back on one signal.
func _arithmetic_output(entity: Entity) -> Dictionary:
	var config: Variant = entity.state.get("arithmetic", null)
	if not (config is Dictionary):
		return {}
	var settings: Dictionary = config
	if not bool(settings.get("enabled", true)):
		return {}
	# Both wires feed one input in Factorio unless the device is told which.
	var input := input_for(entity, str(settings.get("colour", RED)))
	var left := str(settings.get("left", ""))
	var right := str(settings.get("right", ""))
	var out := str(settings.get("out", EACH))

	# `each` applies the operation to every signal in turn.
	if left == EACH or out == EACH:
		var results: Dictionary = {}
		for name: String in (input.keys() if left == EACH else [left]):
			var a := _signal_value(input, name) if left == EACH else _operand(input, left)
			var b := _operand(input, right)
			results[name] = _apply(str(settings.get("op", "+")), a, b)
		if out == EACH:
			return _clean(results)
		return _clean({out: results.values()[0] if not results.is_empty() else 0})
	var a := _operand(input, left)
	var b := _operand(input, right)
	return _clean({out: _apply(str(settings.get("op", "+")), a, b)})


## An operand is either a signal's value or a number written in the box.
func _operand(input: Dictionary, name: String) -> int:
	if name.is_empty():
		return 0
	if name.is_valid_int():
		return int(name)
	if name == EVERYTHING or name == ANYTHING:
		var total := 0
		for other: String in input:
			total += int(input[other])
		return total
	return _signal_value(input, name)


static func _apply(op: String, a: int, b: int) -> int:
	match op:
		"+": return a + b
		"-": return a - b
		"*": return a * b
		"/": return 0 if b == 0 else int(float(a) / float(b))
		"%": return 0 if b == 0 else a % b
		"^": return int(pow(float(a), float(b)))
		"<<": return a << b
		">>": return a >> b
		"AND": return a & b
		"OR": return a | b
		"XOR": return a ^ b
	return a


## The decider combinator: a condition, and a signal to write when it holds.
func _decider_output(entity: Entity) -> Dictionary:
	var config: Variant = entity.state.get("decider", null)
	if not (config is Dictionary):
		return {}
	var settings: Dictionary = config
	if not bool(settings.get("enabled", true)):
		return {}
	var input := input_for(entity, str(settings.get("colour", RED)))
	var left := str(settings.get("left", ""))
	var right := str(settings.get("right", ""))
	var out := str(settings.get("out", ""))
	var value := int(settings.get("value", 1))

	# `each` on a decider decides every signal separately.
	if left == EACH:
		var results: Dictionary = {}
		for name: String in input:
			if _compare(str(settings.get("cmp", ">")), int(input[name]),
					_operand(input, right)):
				results[name if out == EACH or out.is_empty() else out] = value
		return _clean(results)

	var holds := _compare(str(settings.get("cmp", ">")), _operand(input, left),
		_operand(input, right))
	if not holds or out.is_empty():
		return {}
	# Writing "everything" copies the whole input across, which is what makes
	# a decider useful as a filter.
	if out == EVERYTHING:
		return _clean(input)
	return _clean({out: value})


static func _compare(cmp: String, a: int, b: int) -> bool:
	match cmp:
		">": return a > b
		"<": return a < b
		"=": return a == b
		">=": return a >= b
		"<=": return a <= b
		"!=": return a != b
	return false


# --------------------------------------------------------------------------
# tick
# --------------------------------------------------------------------------

## One tick of the whole network.
##
## Writing first and reading after is the one-tick delay: a device this tick
## sees what its neighbours wrote last tick, so a feedback loop counts up
## instead of running away inside a single frame.
func update() -> void:
	if dirty:
		_rebuild()
	_tick += 1
	# 1. Every device sums its wires.  Its members write from the input cached
	#    at the end of the previous tick, so nothing is computed twice over and
	#    a loop cannot recurse.
	for colour: String in COLOURS:
		for network: Dictionary in networks[colour]:
			var sum: Dictionary = {}
			for member: Entity in network["members"]:
				var written := output_of(member)
				for name: String in written:
					sum[name] = int(sum.get(name, 0)) + int(written[name])
			network["signals"] = sum
	# 2. Each device caches what it sees.  A device reads its own output back
	#    along with everyone else's — that is not an oversight, it is what lets
	#    one combinator wired to itself count.
	var fresh: Dictionary = {}
	for colour: String in COLOURS:
		for network: Dictionary in networks[colour]:
			var signals: Dictionary = network["signals"]
			var cleaned: Dictionary = {}
			for name: String in signals:
				if int(signals[name]) != 0:
					cleaned[name] = int(signals[name])
			for member: Entity in network["members"]:
				var seen: Dictionary = fresh.get(member.origin, {})
				seen[colour] = cleaned
				fresh[member.origin] = seen
	_inputs = fresh


## Whether a machine's condition lets it run.  A device with no condition runs.
func enabled(entity: Entity) -> bool:
	var condition: Variant = entity.state.get("circuit_condition", null)
	if not (condition is Dictionary):
		return true
	var settings: Dictionary = condition
	if not bool(settings.get("enabled", false)):
		return true
	var input := input_for(entity, str(settings.get("colour", RED)))
	var left := str(settings.get("left", ""))
	var right := str(settings.get("right", ""))
	if left == EACH or left == ANYTHING:
		for name: String in input:
			if _compare(str(settings.get("cmp", ">")), int(input[name]),
					_operand(input, right)):
				return true
		return false
	if left == EVERYTHING:
		return _compare(str(settings.get("cmp", ">")), _operand(input, EVERYTHING),
			_operand(input, right))
	return _compare(str(settings.get("cmp", ">")), _operand(input, left),
		_operand(input, right))


## A short description of what a device is doing, for its window.
func describe(entity: Entity) -> String:
	match entity.proto_type:
		"constant-combinator":
			var signals: Dictionary = entity.state.get("signals", {})
			return "%d signals" % signals.size()
		"arithmetic-combinator":
			var a: Variant = entity.state.get("arithmetic", null)
			if a is Dictionary:
				var s: Dictionary = a
				return "%s %s %s -> %s" % [s.get("left", "?"), s.get("op", "+"),
					s.get("right", "0"), s.get("out", EACH)]
		"decider-combinator":
			var d: Variant = entity.state.get("decider", null)
			if d is Dictionary:
				var s: Dictionary = d
				return "if %s %s %s -> %s %d" % [s.get("left", "?"),
					s.get("cmp", ">"), s.get("right", "0"), s.get("out", ""),
					int(s.get("value", 1))]
	return ""


func clear() -> void:
	networks = {RED: [], GREEN: []}
	_inputs.clear()
	dirty = true
	_tick = 0


# --------------------------------------------------------------------------
# serialisation
# --------------------------------------------------------------------------

func to_dict() -> Dictionary:
	# Wires live on the entities themselves, so a save already carries them.
	return {"tick": _tick}


func from_dict(data: Dictionary) -> void:
	_tick = int(data.get("tick", 0))
	mark_dirty()
