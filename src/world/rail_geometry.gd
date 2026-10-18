class_name RailGeometry
extends RefCounted
## Where a rail piece begins and ends, and how long it is.
##
## A rail is a 2x2 block, and within that block it is a path: a straight piece
## runs across the block, a curved one turns a corner inside it.  Everything a
## train needs to know is on that path — where it enters, which way it is
## heading there, where it leaves, and how far it is from one end to the other.
##
## Curves here are quarter circles of radius one tile.  Factorio's own rails are
## a little longer and laid out on a different grid, but the topology — which
## piece joins which — is the same, and that is what a train follows.

## The curve that turns clockwise, and the one that turns anticlockwise.
const CLOCKWISE := "curved-rail-a"
const ANTICLOCKWISE := "curved-rail-b"

## Half the circumference of a unit circle: the length of a quarter turn.
const CURVE_LENGTH := PI * 0.5

const EAST := 4
const SOUTH := 8
const WEST := 12
const NORTH := 0


static func is_rail(entity: Entity) -> bool:
	if entity == null:
		return false
	return entity.proto_type in ["straight-rail", CLOCKWISE, ANTICLOCKWISE]


## Whether a rail runs along an axis rather than turning.
static func is_straight(entity: Entity) -> bool:
	return entity != null and entity.proto_type == "straight-rail"


## The path through a rail: ``{ start, end, start_dir, end_dir, length, arc }``
## in tile coordinates, with ``arc`` naming the centre of a curve.
##
## Directions are the 16-way ones the rest of the game uses, so 4 is east and
## 8 is south.
static func path_of(entity: Entity) -> Dictionary:
	if entity == null:
		return {}
	var origin := Vector2(entity.origin)
	var direction := posmod(entity.direction, 16)
	if entity.proto_type == "straight-rail":
		# The rail runs along the axis its direction names.
		if posmod(direction, 8) == 0:
			return {
				"start": origin + Vector2(1, 0),
				"end": origin + Vector2(1, 2),
				"start_dir": SOUTH, "end_dir": SOUTH,
				"length": 2.0, "arc": null,
			}
		return {
			"start": origin + Vector2(0, 1),
			"end": origin + Vector2(2, 1),
			"start_dir": EAST, "end_dir": EAST,
			"length": 2.0, "arc": null,
		}

	# A curve joins two perpendicular sides of the block.  The clockwise piece
	# always turns right and the other always turns left, which is what the two
	# prototypes are for.
	var clockwise := entity.proto_type == CLOCKWISE
	var turns := _turns(clockwise)
	# The direction names which side the train comes in from.
	var entry := int(direction / 4) % 4
	var chosen: Array = turns[entry]
	var centre := origin + Vector2(chosen[2])
	return {
		"start": origin + Vector2(chosen[0]),
		"end": origin + Vector2(chosen[1]),
		"start_dir": int(chosen[3]),
		"end_dir": int(chosen[4]),
		"length": CURVE_LENGTH,
		"arc": centre,
		"radius": 1.0,
	}


## The four turns of one handedness, as
## ``[entry_offset, exit_offset, arc_centre, entry_dir, exit_dir]``.
##
## Index 0 enters from the north heading south, and the rest follow clockwise
## round the block.
static func _turns(clockwise: bool) -> Array:
	if clockwise:
		# North in, east out; and so on round.
		return [
			[Vector2(1, 0), Vector2(2, 1), Vector2(2, 0), SOUTH, EAST],
			[Vector2(2, 1), Vector2(1, 2), Vector2(2, 2), WEST, SOUTH],
			[Vector2(1, 2), Vector2(0, 1), Vector2(0, 2), NORTH, WEST],
			[Vector2(0, 1), Vector2(1, 0), Vector2(0, 0), EAST, NORTH],
		]
	# The mirror image: north in, west out, and so on.
	return [
		[Vector2(1, 0), Vector2(0, 1), Vector2(0, 0), SOUTH, WEST],
		[Vector2(0, 1), Vector2(1, 2), Vector2(0, 2), EAST, SOUTH],
		[Vector2(1, 2), Vector2(2, 1), Vector2(2, 2), NORTH, EAST],
		[Vector2(2, 1), Vector2(1, 0), Vector2(2, 0), WEST, NORTH],
	]


## Where a train is, given how far along its current rail it has travelled.
static func point_at(entity: Entity, distance: float) -> Vector2:
	var path := path_of(entity)
	if path.is_empty():
		return Vector2.ZERO
	var along := clampf(distance, 0.0, float(path["length"]))
	if path["arc"] == null:
		# A straight piece is a plain interpolation.
		return Vector2(path["start"]).lerp(Vector2(path["end"]),
			along / float(path["length"]))
	# A curve is a quarter turn about the arc centre, from the entry side to
	# the exit side.
	var centre := Vector2(path["arc"])
	var start := Vector2(path["start"])
	var angle := _angle_of(start - centre)
	var sweep := PI * 0.5
	if not _sweeps_clockwise(entity, start - centre):
		sweep = -sweep
	var turned := angle + sweep * (along / float(path["length"]))
	var radius := start.distance_to(centre)
	return centre + Vector2(cos(turned), sin(turned)) * radius


static func _angle_of(offset: Vector2) -> float:
	return atan2(offset.y, offset.x)


## Which way a curve turns, read from where its exit sits relative to the
## straight line into it.
static func _sweeps_clockwise(entity: Entity, entry_offset: Vector2) -> bool:
	var path := path_of(entity)
	var exit_offset := Vector2(path["end"]) - Vector2(path["arc"])
	return entry_offset.cross(exit_offset) > 0.0


## The direction a train is heading at a point along a rail.
static func direction_at(entity: Entity, distance: float) -> int:
	var path := path_of(entity)
	if path.is_empty():
		return NORTH
	if path["arc"] == null:
		return int(path["start_dir"])
	# On a curve the heading turns with the radius.
	var now := point_at(entity, distance)
	var ahead := point_at(entity, minf(distance + 0.05, float(path["length"])))
	if ahead.distance_to(now) < 0.0001:
		return int(path["end_dir"])
	return Simulation._direction_from_vector(ahead - now)


## Where the train leaves a rail, in tile coordinates.
static func exit_point(entity: Entity) -> Vector2:
	var path := path_of(entity)
	return Vector2(path["end"]) if not path.is_empty() else Vector2.ZERO


## The heading the train has when it leaves a rail.
static func exit_direction(entity: Entity) -> int:
	var path := path_of(entity)
	return int(path["end_dir"]) if not path.is_empty() else NORTH
