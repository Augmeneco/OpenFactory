class_name Trains
extends RefCounted
## Rails and the trains that run on them.
##
## A rail is a 2x2 entity pointing either north-south or east-west, and a track
## is a run of rails laid end to end in one direction.  A train knows which
## rail its head is on and how far along it, so the carriages behind can be
## placed by walking the track backwards — which is all the geometry a straight
## track needs.
##
## Curves are not laid yet: Factorio's curved rails are separate prototypes
## with their own connection rules, so a track here is a straight run.

## A guard on the walk back along a track, so a broken chain cannot hang.
const MAX_CARRIAGES := 64

var world: GameWorld
## ``[{ carriages, rail, offset, direction, speed, braking }]``
var trains: Array = []
var _moved := 0.0


func _init(world_: GameWorld) -> void:
	world = world_


func stats() -> Dictionary:
	return {"trains": trains.size(), "carriages": _carriage_count(),
		"rails": world.entities_of_type("straight-rail").size(),
		"moved": _moved}


func _carriage_count() -> int:
	var total := 0
	for train: Dictionary in trains:
		total += (train["carriages"] as Array).size()
	return total


static func is_rail(entity: Entity) -> bool:
	return RailGeometry.is_rail(entity)


## Whether a rail can be travelled along heading the way a train is going.
##
## A straight piece takes a train either way along its axis, which is what lets
## one reverse; a curve only takes it the way it bends.
static func runs_along(rail: Entity, direction: int) -> bool:
	if rail == null:
		return false
	var path := RailGeometry.path_of(rail)
	if path.is_empty():
		return false
	var heading := posmod(direction, 16)
	if int(path["start_dir"]) == heading or int(path["end_dir"]) == heading:
		return true
	if RailGeometry.is_straight(rail):
		return posmod(int(path["start_dir"]) + 8, 16) == heading
	return false


# --------------------------------------------------------------------------
# tracks
# --------------------------------------------------------------------------

## The rail a train reaches when it leaves this one.
##
## The exit point sits on the boundary of the block, so the rail that picks it
## up is one of the four blocks that touch that corner.  Matching the heading
## as well as the point is what stops a train jumping onto a track that merely
## crosses its own.
func next_rail(rail: Entity) -> Entity:
	if rail == null:
		return null
	var exit := RailGeometry.exit_point(rail)
	var heading := RailGeometry.exit_direction(rail)
	for candidate: Entity in rails_touching(exit):
		if candidate == rail:
			continue
		var path := RailGeometry.path_of(candidate)
		if path.is_empty():
			continue
		if Vector2(path["start"]).distance_to(exit) > 0.05:
			continue
		if int(path["start_dir"]) == heading:
			return candidate
	return null


## The rail a train came from: the one whose exit is this rail's entry.
func previous_rail(rail: Entity) -> Entity:
	if rail == null:
		return null
	var path := RailGeometry.path_of(rail)
	if path.is_empty():
		return null
	var entry := Vector2(path["start"])
	var heading := int(path["start_dir"])
	for candidate: Entity in rails_touching(entry):
		if candidate == rail:
			continue
		var other := RailGeometry.path_of(candidate)
		if other.is_empty():
			continue
		if Vector2(other["end"]).distance_to(entry) > 0.05:
			continue
		if int(other["end_dir"]) == heading:
			return candidate
	return null


## Every rail whose 2x2 block covers a corner point, which is at most four.
func rails_touching(point: Vector2) -> Array:
	var out: Array = []
	var base := Vector2i(int(floor(point.x)), int(floor(point.y)))
	for offset: Vector2i in [Vector2i.ZERO, Vector2i(-1, 0), Vector2i(0, -1),
			Vector2i(-1, -1)]:
		var entity := world.entity_at(base + offset)
		if entity != null and is_rail(entity) and not entity.is_ghost():
			out.append(entity)
	return out


# --------------------------------------------------------------------------
# trains
# --------------------------------------------------------------------------

## Put a train on a rail, head first, with the carriages strung out behind it.
##
## Returns the train, or ``{}`` when there is no track for it to stand on.
func add_train(carriages: Array, rail: Entity, direction: int) -> Dictionary:
	if not is_rail(rail) or not runs_along(rail, direction) or carriages.is_empty():
		return {}
	var path := RailGeometry.path_of(rail)
	var train := {
		"carriages": carriages.duplicate(),
		"rail": rail.origin,
		"distance": float(path["length"]) * 0.5,
		"direction": direction,
		"speed": 0.0,
		"braking": false,
		"fuel": 0.0,
		"driven": false,
		"automatic": false,
		"schedule": [],
		"schedule_index": 0,
		"wait": 0,
		"lead": rail.origin,
	}
	trains.append(train)
	return train


## How far apart two carriages sit, from the locomotive's own spacing.
static func carriage_spacing() -> float:
	return 2.0 * float(Prototypes.get_p("locomotive", "locomotive").get(
		"connection_distance", 3.0))


## The world position of the head of a train, in tiles.
func head_position(train: Dictionary) -> Vector2:
	var rail := world.entity_at(train["rail"])
	if rail == null:
		return Vector2.ZERO
	return RailGeometry.point_at(rail, float(train.get("distance", 0.0)))


## Where one carriage sits, walking back along the track from the head.
func carriage_position(train: Dictionary, index: int) -> Vector2:
	var at := position_behind(train, float(index) * carriage_spacing())
	if at.is_empty():
		return Vector2.ZERO
	return RailGeometry.point_at(at["rail"], float(at["distance"]))


## Where the train was, a given distance back along the track.
##
## Walking back a curve means asking for the rail that feeds it, which is what
## makes a carriage follow its locomotive round a corner instead of cutting the
## chord.
func position_behind(train: Dictionary, back: float) -> Dictionary:
	var rail: Entity = world.entity_at(train["rail"])
	if rail == null:
		return {}
	var distance := float(train.get("distance", 0.0)) - back
	var guard := 0
	while distance < 0.0 and guard < MAX_CARRIAGES:
		guard += 1
		var previous := previous_rail(rail)
		if previous == null:
			# Off the end of the line, so the carriage bunches up at the
			# buffer rather than sliding off into the grass.
			return {"rail": rail, "distance": 0.0}
		distance += float(RailGeometry.path_of(previous)["length"])
		rail = previous
	var length := float(RailGeometry.path_of(rail)["length"])
	while distance > length and guard < MAX_CARRIAGES:
		# Overlapping a coupling: push through to the next rail.
		guard += 1
		var ahead := next_rail(rail)
		if ahead == null:
			return {"rail": rail, "distance": length}
		distance -= length
		rail = ahead
		length = float(RailGeometry.path_of(rail)["length"])
	return {"rail": rail, "distance": distance}


## The carriage standing over a cell, if any.
##
## Carriages are not world entities — the train moves them — so a click on the
## track has to ask the trains what is there.
func carriage_at(cell: Vector2i) -> Dictionary:
	for train: Dictionary in trains:
		for index in (train["carriages"] as Array).size():
			var position := carriage_position(train, index)
			if absf(position.x - (float(cell.x) + 0.5)) <= 2.0 \
					and absf(position.y - (float(cell.y) + 0.5)) <= 2.0:
				return {"train": train, "index": index,
					"name": str((train["carriages"] as Array)[index])}
	return {}


## The locomotive leading a train, as the window's label for it.
static func lead_name(train: Dictionary) -> String:
	var carriages: Array = train.get("carriages", [])
	return str(carriages[0]) if not carriages.is_empty() else "locomotive"


# --------------------------------------------------------------------------
# tick
# --------------------------------------------------------------------------

## Move every train that is under way, and keep the carriages behind the head.
func update() -> void:
	for train: Dictionary in trains:
		update_automatic(train)
	for train: Dictionary in trains:
		var speed := float(train["speed"])
		if is_zero_approx(speed):
			continue
		var rail := world.entity_at(train["rail"])
		if rail == null:
			train["speed"] = 0.0
			continue

		var length := float(RailGeometry.path_of(rail)["length"])
		var distance := float(train.get("distance", 0.0)) + speed
		if distance > length:
			var ahead := next_rail(rail)
			if ahead == null:
				# End of the line, so the train stops at the buffers.
				train["distance"] = length
				train["speed"] = 0.0
				train["braking"] = false
				continue
			train["rail"] = ahead.origin
			distance -= length
			train["direction"] = RailGeometry.direction_at(ahead,
				minf(distance, 0.05))
		elif distance < 0.0:
			var behind := previous_rail(rail)
			if behind == null:
				train["distance"] = 0.0
				train["speed"] = 0.0
				train["braking"] = false
				continue
			train["rail"] = behind.origin
			distance += float(RailGeometry.path_of(behind)["length"])
			# The heading stays the direction of *increasing* distance along
			# the track even when the train is running backwards.  Flipping it
			# here would flip the sign of every station's bearing as well, and
			# the train would hunt back and forth instead of reversing.
			train["direction"] = RailGeometry.direction_at(behind,
				maxf(distance - 0.05, 0.0))
		train["distance"] = distance
		_moved += absf(speed)


## Push a train forward or backward.  The command is a signed acceleration in
## tiles per tick squared.
func drive(train: Dictionary, throttle: float) -> void:
	var locomotive := Prototypes.get_p("locomotive", "locomotive")
	var limit := float(locomotive.get("max_speed", 1.2))
	var speed := float(train["speed"]) + throttle
	train["speed"] = clampf(speed, -limit * 0.5, limit)
	train["driven"] = true


## Brake towards a standstill at the locomotive's own force.
func brake(train: Dictionary, force := 1.0) -> void:
	var speed := float(train["speed"])
	var step := 0.02 * force
	if absf(speed) <= step:
		train["speed"] = 0.0
		train["braking"] = false
		return
	train["speed"] = speed - signf(speed) * step


## A Vector2i back from the list a save file holds, or ``ZERO``.
static func _to_cell(value: Variant) -> Vector2i:
	if value is Array and (value as Array).size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return Vector2i.ZERO


func clear() -> void:
	trains.clear()


# --------------------------------------------------------------------------
# serialisation
# --------------------------------------------------------------------------

func to_dict() -> Array:
	var out: Array = []
	for train: Dictionary in trains:
		out.append({
			"carriages": train["carriages"],
			"rail": [(train["rail"] as Vector2i).x, (train["rail"] as Vector2i).y],
			"distance": float(train.get("distance", 0.0)),
			"direction": int(train["direction"]),
			"speed": float(train["speed"]),
			"automatic": bool(train.get("automatic", false)),
			"schedule": train.get("schedule", []),
			"schedule_index": int(train.get("schedule_index", 0)),
			"wait": int(train.get("wait", 0)),
			"lead": [(train["lead"] as Vector2i).x, (train["lead"] as Vector2i).y]
				if train.get("lead") is Vector2i else null,
		})
	return out


func from_dict(data: Array) -> void:
	clear()
	for entry: Variant in data:
		if not (entry is Dictionary):
			continue
		var rail: Variant = entry.get("rail", null)
		if not (rail is Array) or (rail as Array).size() < 2:
			continue
		trains.append({
			"carriages": entry.get("carriages", []),
			"rail": Vector2i(int(rail[0]), int(rail[1])),
			"distance": float(entry.get("distance", 1.0)),
			"direction": int(entry.get("direction", 0)),
			"speed": float(entry.get("speed", 0.0)),
			"braking": false,
			"fuel": 0.0,
			"driven": false,
			"automatic": bool(entry.get("automatic", false)),
			"schedule": entry.get("schedule", []),
			"schedule_index": int(entry.get("schedule_index", 0)),
			"wait": int(entry.get("wait", 0)),
			"lead": _to_cell(entry.get("lead")),
		})


# --------------------------------------------------------------------------
# stations and schedules
# --------------------------------------------------------------------------

## The name on a train stop, which is what a schedule asks for.
static func station_of(stop: Entity) -> String:
	return str(stop.state.get("station", "Station"))


## Every stop on the track the train is standing on.
##
## A straight track has one axis, so a stop belongs to it when it sits beside
## the rails rather than off in the weeds: the sideways offset is under two
## tiles.  Once it belongs, the distance along the axis is the distance the
## train has to travel — negative meaning it is behind.
func stops_on_track(train: Dictionary, name := "") -> Array:
	var head := head_position(train)
	var axis := Vector2(BeltSim.dir_vector(int(train["direction"])))
	var sideways := Vector2(-axis.y, axis.x)
	var found: Array = []
	for entity: Entity in world.entities_of_type("train-stop"):
		if entity.is_ghost():
			continue
		var delta := entity.center() - head
		if absf(delta.dot(sideways)) > 2.0:
			continue
		if not name.is_empty() and station_of(entity) != name:
			continue
		found.append({"stop": entity, "along": delta.dot(axis)})
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return absf(float(a["along"])) < absf(float(b["along"])))
	return found


## The stop of a given name the train should head for, or ``null``.
func next_stop(train: Dictionary, name: String) -> Entity:
	var found := stops_on_track(train, name)
	if found.is_empty():
		return null
	return found[0]["stop"]


## Where the train is in its schedule, and how long it is still waiting.
static func schedule_of(train: Dictionary) -> Array:
	return train.get("schedule", [])


## Tick a train that is driving itself.
##
## It runs at whatever speed still lets it stop before the station — the same
## square-root approach a vehicle uses — waits out its dwell time, then asks
## for the next name on the list.
func update_automatic(train: Dictionary) -> void:
	if not bool(train.get("automatic", false)):
		return
	var schedule: Array = train.get("schedule", [])
	if schedule.is_empty():
		brake(train)
		return
	var index := int(train.get("schedule_index", 0)) % schedule.size()
	var wanted := str(schedule[index])
	var stop := next_stop(train, wanted)
	if stop == null:
		# Nothing by that name on this track, so the train waits where it is.
		brake(train)
		return

	if int(train.get("wait", 0)) > 0:
		train["wait"] = int(train["wait"]) - 1
		brake(train, 2.0)
		if int(train["wait"]) == 0:
			train["schedule_index"] = (index + 1) % schedule.size()
		return

	var axis := Vector2(BeltSim.dir_vector(int(train["direction"])))
	var along := (stop.center() - head_position(train)).dot(axis)
	if absf(along) <= 1.0:
		# Arrived: stand at the station for its dwell time.
		brake(train, 3.0)
		if is_zero_approx(float(train["speed"])):
			train["wait"] = dwell_ticks()
		return

	# Point the train at the station before moving — it may need to reverse.
	var wanted_direction := int(train["direction"])
	if along < 0.0:
		wanted_direction = posmod(int(train["direction"]) + 8, 16)
		if not runs_along_anywhere(train, wanted_direction):
			brake(train)
			return
	elif not runs_along_anywhere(train, int(train["direction"])):
		brake(train)
		return

	# Slow enough to stop within the distance that is left.
	var stop_speed := sqrt(maxf(0.0, 2.0 * 0.004 * absf(along)))
	var speed := float(train["speed"])
	var heading := signf(speed) if not is_zero_approx(speed) else 1.0
	var toward := signf(along)
	if not is_zero_approx(speed) and heading != toward:
		# Still rolling the wrong way: brake first, then turn around.
		brake(train, 2.0)
		return
	drive(train, toward * 0.02)
	var now := float(train["speed"])
	if absf(now) > stop_speed:
		train["speed"] = toward * stop_speed


## Whether the train can travel in a direction from where it stands.
func runs_along_anywhere(train: Dictionary, direction: int) -> bool:
	var rail := world.entity_at(train["rail"])
	return runs_along(rail, direction)


## How long a train stands at a station.  Factorio's default is two seconds.
static func dwell_ticks() -> int:
	return 120
