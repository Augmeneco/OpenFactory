class_name Character
extends RefCounted
## The player's engineer.
##
## Movement, collision and hand mining follow the ``character`` prototype:
## ``running_speed`` 0.15 tiles per tick (9 tiles a second), a 0.4 tile
## collision box, ``mining_speed`` 0.5 and ``reach_distance`` 10.  The idle and
## running animations are the real 8-direction sheets, including the mask layer
## Factorio tints with the player's colour.

const TILE := 32.0
const TICKS_PER_SECOND := 60

var world: GameWorld

var position := Vector2.ZERO            ## centre of the character, in tiles
var velocity := Vector2.ZERO
var direction := 8                      ## defines.direction, facing south
var animation := "idle"
var animation_ticks := 0.0
var colour := Color(0.35, 0.62, 0.95)   ## player colour for the mask layer

## Hand mining.
var mining_target: Dictionary = {}      ## {} | { kind = "resource"/"entity", ... }
var mining_progress := 0.0

signal mined(item_name: String, amount: int)
signal mined_entity(entity_name: String)
signal mining_changed
## Health changed, or the engineer was hurt / healed / died.
signal health_changed(health: float, max_health: float)
signal damaged(amount: float)
signal died

## The armour and the equipment in it.
var equipment := EquipmentGrid.new()
## Current and maximum health, from the ``character`` prototype.
var health := 0.0
var max_health := 0.0
## Ticks left before the engineer can shoot again.
var fire_cooldown := 0
var shots_fired := 0

## The technology tree, so upgrades can reach the engineer's numbers.
var research: Research

var _proto: Dictionary = {}
## Belts keep driving the engineer while the world runs; the pause menu turns
## this off through the player.
var belt_drive := true

## Things the engineer walks over instead of bumping into.  Factorio's belts,
## inserters and power poles are floor furniture, not walls.
const WALKABLE := [
	"transport-belt", "underground-belt", "splitter", "inserter",
	"electric-pole", "big-electric-pole", "substation", "item-entity",
	"straight-rail", "curved-rail-a", "curved-rail-b", "rail-ramp",
]


func _init(world_: GameWorld, spawn := Vector2(0.5, 0.5)) -> void:
	world = world_
	position = spawn
	_proto = Prototypes.get_p("character", "character")
	max_health = float(_proto.get("max_health", 250.0))
	health = max_health


func _ready() -> void:
	pass


# --------------------------------------------------------------------------
# prototype values
# --------------------------------------------------------------------------

## Base walking speed plus whatever the exoskeletons add.  Factorio's own
## exoskeleton carries `movement_bonus` 0.3, and the bonuses add up.
func running_speed() -> float:
	var base := float(_proto.get("running_speed", 0.15))
	return base * (1.0 + float(equipment.effects()["movement_bonus"]))


func mining_speed() -> float:
	var base := float(_proto.get("mining_speed", 0.5))
	if research != null and research.modifiers != null:
		base *= research.modifiers.character_mining_speed_multiplier()
	return base


func reach_distance() -> float:
	return float(_proto.get("reach_distance", 10.0))


## Put the shield back up and let the equipment work.  Called every tick.
func tick_equipment(delta: float) -> void:
	equipment.recharge(delta)


## Health regained per tick while alive.
func healing_per_tick() -> float:
	return float(_proto.get("healing_per_tick", 0.0))


func health_fraction() -> float:
	return health / maxf(1.0, max_health)


func is_alive() -> bool:
	return health > 0.0


## Take a hit, applying the character prototype's resistances if it has any.
## Returns the damage actually taken.
func take_damage(amount: float, damage_type := "physical") -> float:
	if amount <= 0.0 or not is_alive():
		return 0.0
	var dealt := Simulation.after_resistances(_proto, amount, damage_type)
	# The shield takes the hit first, and only what is left reaches the
	# engineer — which is the whole point of wearing it.
	dealt = equipment.absorb(dealt)
	if dealt <= 0.0:
		damaged.emit(0.0)
		return 0.0
	health = maxf(0.0, health - dealt)
	damaged.emit(dealt)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		died.emit()
	return dealt


## Recompute the health ceiling, which research can raise.
##
## Returns true when it changed, so a caller can announce it.
func refresh_health_bonus() -> bool:
	var base := float(_proto.get("max_health", 250.0))
	if research != null and research.modifiers != null:
		base += research.modifiers.character_health_bonus()
	if is_equal_approx(base, max_health):
		return false
	var was_full := health >= max_health
	max_health = base
	if was_full:
		health = max_health
	health_changed.emit(health, max_health)
	return true


## Natural regeneration, and the countdown on the trigger.
func advance_health(delta_ticks := 1.0) -> void:
	if fire_cooldown > 0:
		fire_cooldown = maxi(0, fire_cooldown - int(round(delta_ticks)))
	if not is_alive():
		return
	var healing := healing_per_tick()
	if healing <= 0.0 or health >= max_health:
		return
	health = minf(max_health, health + healing * delta_ticks)
	health_changed.emit(health, max_health)


## Stand up again at ``where`` with full health.
func respawn(where: Vector2) -> void:
	position = where
	health = max_health
	fire_cooldown = 0
	velocity = Vector2.ZERO
	cancel_mining()
	health_changed.emit(health, max_health)


func radius() -> float:
	var box: Variant = _proto.get("collision_box")
	if box is Array and box.size() == 2:
		var a := FactorioAssets.parse_vector(box[0])
		var b := FactorioAssets.parse_vector(box[1])
		return maxf(0.05, (b.x - a.x) * 0.5)
	return 0.2


# --------------------------------------------------------------------------
# movement
# --------------------------------------------------------------------------

## Advance one 60 Hz tick.  ``input`` is a direction vector in screen space.
func tick(input: Vector2, delta_ticks := 1.0) -> void:
	var wanted := input.limit_length(1.0)
	velocity = wanted * running_speed() * delta_ticks

	if wanted.length_squared() > 0.0001:
		direction = _direction_from_vector(wanted)
		animation = "running"
	else:
		animation = "mining" if not mining_target.is_empty() else "idle"

	# Move one axis at a time so sliding along a wall still works.
	var motion := velocity
	# A save or an old spawn can put the engineer inside a machine.  In that
	# state every direction is blocked, so let them walk straight out instead
	# of being permanently trapped.
	var stuck := blocked(position)
	if not is_zero_approx(motion.x) and (stuck or not blocked(position + Vector2(motion.x, 0.0))):
		position.x += motion.x
	if not is_zero_approx(motion.y) and (stuck or not blocked(position + Vector2(0.0, motion.y))):
		position.y += motion.y

	# A belt under the engineer carries them at the same speed it carries
	# items.  The prototype's `speed` is tiles per tick, exactly what
	# BeltSim.update uses.
	if belt_drive:
		var belt := _belt_under()
		if belt != null:
			var speed := float(belt.prototype().get("speed", 0.03125))
			var belt_motion := Vector2(BeltSim.dir_vector(belt.direction)) \
				* speed * delta_ticks
			if belt_motion.length_squared() > 0.0 \
					and not blocked(position + belt_motion):
				position += belt_motion
				animation = "running"

	animation_ticks += delta_ticks


## Factorio's 16-way direction from a movement vector, clockwise from north.
static func _direction_from_vector(v: Vector2) -> int:
	var angle := atan2(v.y, v.x)          # 0 = east, positive = south
	var clockwise_from_north := fposmod(rad_to_deg(angle) + 90.0, 360.0)
	return posmod(int(round(clockwise_from_north / 22.5)), 16)


## Whether the character's box would overlap something solid at ``where``.
func blocked(where: Vector2) -> bool:
	var r := radius()
	for corner: Vector2 in [
		Vector2(-r, -r), Vector2(r, -r), Vector2(-r, r), Vector2(r, r),
	]:
		var cell := Vector2i(int(floor(where.x + corner.x)), int(floor(where.y + corner.y)))
		if _solid_tile(cell):
			return true
		var entity := world.entity_at(cell)
		if entity != null and _blocks(entity, where, r):
			return true
	return false


func _solid_tile(cell: Vector2i) -> bool:
	var tile := world.tile_at(cell)
	if tile.is_empty():
		return false
	return tile.begins_with("water") or tile.begins_with("deepwater")


## Entities block by their footprint; the player can walk between them but not
## through them.
func _blocks(entity: Entity, where: Vector2, r: float) -> bool:
	if WALKABLE.has(entity.proto_type):
		return false
	var rect := Rect2(Vector2(entity.origin), Vector2(entity.size))
	var player := Rect2(where - Vector2(r, r), Vector2(r * 2.0, r * 2.0))
	return rect.intersects(player)


## The first belt under the engineer's body, if any.
func _belt_under() -> Entity:
	var r := radius()
	for offset: Vector2 in [Vector2.ZERO, Vector2(-r, 0), Vector2(r, 0),
			Vector2(0, -r), Vector2(0, r)]:
		var probe := position + offset
		var entity := world.entity_at(
			Vector2i(int(floor(probe.x)), int(floor(probe.y))))
		if entity != null and BeltSim.is_belt(entity):
			return entity
	return null


func cell() -> Vector2i:
	return Vector2i(int(floor(position.x)), int(floor(position.y)))


func within_reach(cell_: Vector2i) -> bool:
	return position.distance_to(Vector2(cell_) + Vector2(0.5, 0.5)) <= reach_distance()


# --------------------------------------------------------------------------
# hand mining
# --------------------------------------------------------------------------

## Begin (or continue) mining whatever is at ``cell``.  Returns true when the
## target changed.
func set_mining_target(cell: Vector2i) -> bool:
	var entity := world.entity_at(cell)
	var ore := world.ore_at(cell)
	var target: Dictionary = {}
	if entity != null and _is_minable(entity):
		target = {"kind": "entity", "cell": cell, "name": entity.name,
			"type": entity.proto_type}
	elif not str(ore["name"]).is_empty() and float(ore["amount"]) > 0.0:
		target = {"kind": "resource", "cell": cell, "name": str(ore["name"]),
			"type": "resource"}
	if target.is_empty():
		if mining_target.is_empty():
			return false
		mining_target = {}
		mining_progress = 0.0
		mining_changed.emit()
		return true
	var same: bool = not mining_target.is_empty() and mining_target.get("cell") == cell
	mining_target = target
	if not same:
		mining_progress = 0.0
		mining_changed.emit()
	return not same


func cancel_mining() -> void:
	if mining_target.is_empty():
		return
	mining_target = {}
	mining_progress = 0.0
	mining_changed.emit()


static func _is_minable(entity: Entity) -> bool:
	var proto := entity.prototype()
	var minable: Variant = proto.get("minable")
	return minable is Dictionary


## Time in ticks to mine the current target.
func mining_ticks() -> float:
	if mining_target.is_empty():
		return 0.0
	var mining_time := 1.0
	var proto: Dictionary
	if str(mining_target.get("kind")) == "resource":
		proto = Prototypes.get_p("resource", str(mining_target["name"]))
	else:
		proto = Prototypes.get_p(str(mining_target.get("type", "item")),
			str(mining_target["name"]))
	var minable: Variant = proto.get("minable", {})
	if minable is Dictionary:
		mining_time = float(minable.get("mining_time", 1.0))
	return maxf(1.0, (mining_time / maxf(mining_speed(), 1e-6)) * TICKS_PER_SECOND)


## Advance hand mining by ``delta_ticks``; emits ``mined`` on completion.
func advance_mining(delta_ticks := 1.0) -> void:
	if mining_target.is_empty():
		return
	var total := mining_ticks()
	mining_progress += delta_ticks / total
	if mining_progress < 1.0:
		return
	mining_progress = 0.0
	_finish_mining()


func _finish_mining() -> void:
	var cell: Vector2i = mining_target["cell"]
	if str(mining_target["kind"]) == "resource":
		var ore := world.ore_at(cell)
		var ore_name := str(ore["name"])
		if ore_name.is_empty():
			mining_target = {}
			return
		var proto := Prototypes.get_p("resource", ore_name)
		var minable: Variant = proto.get("minable", {})
		var amount := 1
		var results: Array = []
		if minable is Dictionary:
			results = minable.get("results", [])
			if results.is_empty() and minable.has("result"):
				amount = int(minable.get("count", 1))
				results = [{"name": minable["result"], "amount": amount}]
		if results.is_empty():
			results = [{"name": ore_name, "amount": 1}]
		for result: Dictionary in results:
			var name := str(result.get("name", ore_name))
			var count := int(result.get("amount", 1))
			var taken := int(world.mine_ore(cell, float(count)))
			if taken > 0:
				mined.emit(name, taken)
		# Keep mining the same tile until it runs out.
		if float(world.ore_at(cell)["amount"]) <= 0.0:
			mining_target = {}
	else:
		var entity := world.entity_at(cell)
		if entity == null:
			mining_target = {}
			return
		var proto := entity.prototype()
		var minable: Variant = proto.get("minable", {})
		var results: Array = []
		if minable is Dictionary:
			results = minable.get("results", [])
			if results.is_empty() and minable.has("result"):
				results = [{"name": minable["result"],
					"amount": minable.get("count", 1)}]
		if results.is_empty():
			results = [{"name": entity.name, "amount": 1}]
		# A broken belt hands over whatever was riding on it, not just itself.
		if BeltSim.is_belt(entity):
			for item: Dictionary in BeltSim.items_of(entity):
				mined.emit(str(item.get("name", "")), int(item.get("count", 0)))
			BeltSim.items_of(entity).clear()
		# Anything the machine was holding spills out too.
		for key: String in entity.state.get("inventories", {}):
			var inv: Variant = entity.state["inventories"][key]
			if inv is Inventory:
				for entry: Variant in (inv as Inventory).slots:
					if entry != null:
						mined.emit(str(entry["name"]), int(entry["count"]))
		mined_entity.emit(entity.name)
		world.remove_entity(entity)
		for result: Dictionary in results:
			mined.emit(str(result["name"]), int(result.get("amount", 1)))
		mining_target = {}
	mining_changed.emit()


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

func animation_graphics() -> Variant:
	var groups: Variant = _proto.get("animations")
	if not (groups is Array) or groups.is_empty():
		return null
	var group: Variant = groups[0]
	if not (group is Dictionary):
		return null
	var key := "running" if animation == "running" else \
		("mining_with_tool" if animation == "mining" else "idle")
	if group.has(key):
		return group[key]
	return group.get("idle")


func animation_speed() -> float:
	var node: Variant = animation_graphics()
	if node is Dictionary:
		for layer: Variant in node.get("layers", []):
			if layer is Dictionary and layer.has("animation_speed"):
				return float(layer["animation_speed"])
	return 0.15


func animation_frame_count() -> int:
	var node: Variant = animation_graphics()
	if node is Dictionary:
		for layer: Variant in node.get("layers", []):
			if layer is Dictionary and layer.has("frame_count"):
				return maxi(1, int(layer["frame_count"]))
	return 1


func animation_frame() -> int:
	return posmod(int(animation_ticks * animation_speed()), animation_frame_count())


## Layers to draw, with the player colour applied to the mask.
func render_layers() -> Array:
	var graphics := animation_graphics()
	if graphics == null:
		return []
	var layers: Array = SpriteCache.layers(graphics, direction, animation_frame(), 0,
		"character/%s" % animation)
	var out: Array = []
	for layer: SpriteSource.Layer in layers:
		var copy := layer.duplicate_layer()
		if copy.runtime_tint:
			copy.modulate = Color(colour.r, colour.g, colour.b, 1.0)
		out.append(copy)
	return out


## Centre of the character in world pixels.
func world_position() -> Vector2:
	return position * TILE


func mining_fraction() -> float:
	if mining_target.is_empty():
		return -1.0
	return mining_progress
