class_name BeltSim
extends RefCounted
## Transport belt simulation.
##
## Factorio's belts carry items in two lanes at a fixed linear density: a
## yellow belt moves 0.03125 tiles per tick, items take 0.25 tiles each, so a
## lane delivers 0.03125 / 0.25 = 7.5 items per second and a full belt 15 —
## exactly the numbers in the game.  This reproduces that model: item
## positions live in ``[0, 1)`` inside their belt tile, items may never pass
## the one ahead, and an item leaving a tile is handed to the belt its
## direction points at.

## Tiles occupied by one item on a belt lane.
const SPACING := 0.25
## Distance of a lane from the belt centreline.
const LANE_OFFSET := 0.25
const LANES := 2

## Factorio's four belt directions, as tile offsets.
const DIRECTION_VECTORS := {
	0: Vector2i(0, -1),
	4: Vector2i(1, 0),
	8: Vector2i(0, 1),
	12: Vector2i(-1, 0),
}


static func dir_vector(direction: int) -> Vector2i:
	return DIRECTION_VECTORS.get(posmod(direction, 16), Vector2i(0, -1))


## Items stored on a belt, created on first use.
static func items_of(belt: Entity) -> Array:
	var items: Variant = belt.state.get("items")
	if items is Array:
		return items
	var made: Array = []
	belt.state["items"] = made
	return made


static func is_belt(entity: Entity) -> bool:
	if entity == null:
		return false
	return entity.proto_type in ["transport-belt", "underground-belt", "splitter"]


## The belt this one hands items to through the shared tile seam.
##
## Only a plain belt qualifies: a splitter and an underground entrance take
## items by pulling from the belt behind them, because both keep their own
## bookkeeping (a round-robin cursor, a tunnel queue) that a blind append
## would corrupt.
static func next_of(world: GameWorld, belt: Entity) -> Entity:
	var neighbour := world.entity_at(belt.origin + dir_vector(belt.direction))
	if neighbour == null or neighbour.proto_type != "transport-belt":
		return null
	return neighbour


## The belt feeding this one.  A splitter counts, since it pushes into the
## belts in front of it.
static func prev_of(world: GameWorld, belt: Entity) -> Entity:
	var neighbour := world.entity_at(belt.origin - dir_vector(belt.direction))
	return neighbour if is_belt(neighbour) else null


## Unit vector of a lane's sideways offset, for drawing and for deciding which
## lane an inserter reaches.
static func lane_offset_vector(direction: int) -> Vector2:
	var forward := Vector2(dir_vector(direction))
	return Vector2(-forward.y, forward.x)


# --------------------------------------------------------------------------
# tick
# --------------------------------------------------------------------------

static func update(world: GameWorld, belt: Entity) -> void:
	var items := items_of(belt)
	if items.is_empty():
		return

	var speed := float(belt.prototype().get("speed", 0.03125))
	if speed <= 0.0:
		return
	var next_belt := next_of(world, belt)

	# The rear item of the belt ahead limits how far items may travel here.
	# Without this the tile seam would let two items touch: one at position 1.0
	# on this tile and one at 0.0 on the next.
	var next_rear := [INF, INF]
	if next_belt != null:
		for other: Dictionary in items_of(next_belt):
			var other_lane: int = clampi(int(other["lane"]), 0, LANES - 1)
			next_rear[other_lane] = minf(next_rear[other_lane], float(other["pos"]))

	# Rebuilt rather than mutated in place: Dictionary equality is by value in
	# Godot 4, so Array.erase() could remove a different item.
	var kept: Array = []
	for lane in LANES:
		var lane_items: Array = []
		for item: Dictionary in items:
			if int(item["lane"]) == lane:
				lane_items.append(item)
		if lane_items.is_empty():
			continue
		lane_items.sort_custom(_front_first)

		# Furthest this lane may advance, measured from this tile's origin.
		var lane_cap := 1.0
		var rear: float = next_rear[lane]
		if rear < INF:
			lane_cap = 1.0 + rear - SPACING

		var ahead := INF
		for item: Dictionary in lane_items:
			var old_pos := float(item["pos"])
			var target := minf(old_pos + speed, lane_cap)

			# Past the end: hand the item to the belt this one feeds.
			if target >= 1.0 and next_belt != null \
					and _accept(next_belt, item, lane, target - 1.0):
				continue

			var limit := ahead - SPACING
			if target > limit:
				target = limit
			if target < old_pos:
				target = old_pos
			item["pos"] = target
			ahead = target
			kept.append(item)
	items.assign(kept)


static func _front_first(a: Dictionary, b: Dictionary) -> bool:
	return float(a["pos"]) > float(b["pos"])


## Hand an item to the belt behind this one, if there is room for it.
static func _accept(belt: Entity, item: Dictionary, lane: int, position: float) -> bool:
	var target_items := items_of(belt)
	var rear := INF
	for other: Dictionary in target_items:
		if int(other["lane"]) != lane:
			continue
		rear = minf(rear, float(other["pos"]))
	if rear < INF and position > rear - SPACING:
		return false
	target_items.append({
		"lane": lane,
		"pos": maxf(position, 0.0),
		"name": str(item["name"]),
		"count": int(item["count"]),
	})
	return true


# --------------------------------------------------------------------------
# transfers
# --------------------------------------------------------------------------

## Rear-most item position in a lane (``INF`` when the lane is empty).
static func lane_rear(belt: Entity, lane: int) -> float:
	var rear := INF
	for item: Dictionary in items_of(belt):
		if int(item["lane"]) == lane:
			rear = minf(rear, float(item["pos"]))
	return rear


## Whether there is room for a new item at the rear of a lane.
static func lane_has_space(belt: Entity, lane: int) -> bool:
	return lane_rear(belt, lane) >= SPACING


## Put items onto the belt at its rear.  Returns the amount that fit.
##
## The preferred lane is used when it has room; otherwise the other lane is
## tried, so an inserter is never deadlocked by a single full lane.
static func try_insert(belt: Entity, item_name: String, amount: int,
		preferred_lane := -1) -> int:
	if amount <= 0:
		return 0
	var items := items_of(belt)

	var order: Array = []
	if preferred_lane >= 0 and preferred_lane < LANES:
		order = [preferred_lane, 1 - preferred_lane]
	else:
		order = [0, 1]
		# Prefer whichever lane has the most room at its rear.
		if lane_rear(belt, 1) > lane_rear(belt, 0):
			order = [1, 0]

	for lane: int in order:
		if not lane_has_space(belt, lane):
			continue
		items.append({"lane": lane, "pos": 0.0, "name": item_name, "count": amount})
		return amount
	return 0


## Take the leading item off a belt lane.  Returns ``{name, count}`` or ``{}``.
static func take_one(belt: Entity, preferred_lane := -1) -> Dictionary:
	var items := items_of(belt)
	var best: Variant = null
	for item: Dictionary in items:
		if preferred_lane >= 0 and int(item["lane"]) != preferred_lane:
			continue
		if best == null or float(item["pos"]) > float(best["pos"]):
			best = item
	if best == null:
		return {}
	items.erase(best)
	return {"name": str(best["name"]), "count": int(best["count"])}


## Peek without removing, used to decide whether an inserter has work.
static func peek_one(belt: Entity, preferred_lane := -1) -> Dictionary:
	var items := items_of(belt)
	var best: Variant = null
	for item: Dictionary in items:
		if preferred_lane >= 0 and int(item["lane"]) != preferred_lane:
			continue
		if best == null or float(item["pos"]) > float(best["pos"]):
			best = item
	if best == null:
		return {}
	return {"name": str(best["name"]), "count": int(best["count"])}


## Which lane an object at ``world_position`` reaches: 0 is the left side of
## the belt's direction of travel.
static func lane_for_position(belt: Entity, world_position: Vector2) -> int:
	var offset := lane_offset_vector(belt.direction)
	var relative := world_position - (Vector2(belt.origin) + Vector2(0.5, 0.5))
	return 0 if relative.dot(offset) < 0.0 else 1


## World position of an item on a belt, for rendering.
static func item_world_position(belt: Entity, item: Dictionary,
		world: GameWorld = null) -> Vector2:
	var direction := posmod(belt.direction, 16)
	var lane_sign := -1.0 if int(item["lane"]) == 0 else 1.0
	var centre := Vector2(belt.origin) + Vector2(0.5, 0.5)
	var input := curve_input_side(world, belt) if world != null else -1
	if input >= 0:
		# A belt curve is a quarter circle around the corner shared by its
		# input and output edges.  Items used to be drawn along the output
		# straight line, which made them float over the corner instead of
		# following the belt surface.
		var out_vector := Vector2(dir_vector(direction))
		var in_vector := Vector2(dir_vector(input))
		var corner := centre + (in_vector + out_vector) * 0.5
		var start_angle := (centre + in_vector * 0.5 - corner).angle()
		var end_angle := (centre + out_vector * 0.5 - corner).angle()
		var sweep := wrapf(end_angle - start_angle, -PI, PI)
		var angle := start_angle + sweep * float(item["pos"])
		var radial := Vector2(cos(angle), sin(angle))
		# The lane offset is perpendicular to the direction of travel, not
		# radial: at the exit of a north-to-east curve the item travels east,
		# so its two lanes must sit north and south of the centre line.
		var tangent := Vector2(-sin(angle), cos(angle)) * (1.0 if sweep >= 0.0 else -1.0)
		var normal := Vector2(-tangent.y, tangent.x)
		return corner + radial * 0.5 + normal * (LANE_OFFSET * lane_sign)
	var forward := Vector2(dir_vector(direction))
	var side := lane_offset_vector(direction)
	return centre + forward * (float(item["pos"]) - 0.5) \
		+ side * (LANE_OFFSET * lane_sign)


## The side a curved belt receives items from, or -1 for a straight belt.
## This mirrors ``EntityVisuals.belt_shape_row`` so sprite and item path use
## exactly the same choice.
static func curve_input_side(world: GameWorld, belt: Entity) -> int:
	var direction := posmod(belt.direction, 16)
	var back := posmod(direction + 8, 16)
	if _belt_feeds(world, belt, back):
		return -1
	for offset: int in [4, 12]:
		var side := posmod(direction + offset, 16)
		if _belt_feeds(world, belt, side):
			return side
	return -1


static func _belt_feeds(world: GameWorld, belt: Entity, from_direction: int) -> bool:
	var feeder := world.entity_at(belt.origin + dir_vector(from_direction))
	if not is_belt(feeder):
		return false
	return posmod(feeder.direction, 16) == posmod(from_direction + 8, 16)


## Total number of items currently on every belt of the world (diagnostics).
static func total_items(world: GameWorld) -> int:
	var sum := 0
	for entity: Entity in world.entities.values():
		if not is_belt(entity):
			continue
		sum += items_of(entity).size()
	return sum
