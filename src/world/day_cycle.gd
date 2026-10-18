class_name DayCycle
extends RefCounted
## The time of day, and the colour it puts over the world.
##
## Factorio does not darken the screen by blending a colour: it keeps a
## `daytime_color_lookup` in its utility constants — a list of
## ``[time_of_day, lut]`` pairs where the lut is either `identity` or a colour
## table — and runs the whole frame through it.  That curve is in the dump, so
## the shape of the night here is the original's.
##
## The length of a cycle is not in the dump.  Factorio's default is a little
## over seven minutes from dawn to dawn, and that is the constant used below;
## it is a number this build assumes rather than one it read.

## Seconds for one full cycle.  Factorio's default; not present in the dump.
const DAY_SECONDS := 420.0
const TICKS_PER_DAY := int(DAY_SECONDS * 60.0)

## Where the day is.  Factorio counts **0 as noon** and 0.5 as midnight, which
## is what its own `daytime_color_lookup` says: the table is `identity` — no
## colour change at all — at 0, and the night table at 0.45 to 0.55.
var time_of_day := 0.0
var enabled := true
## How much a night-vision unit lifts the darkness, from the equipment.
var night_vision := false

var _curve: Array = []


func _init() -> void:
	_load_curve()


## The `[time, lut]` pairs, normalised into something that can be sampled.
func _load_curve() -> void:
	var constants := Prototypes.get_p("utility-constants", "default")
	var lookup: Variant = constants.get("daytime_color_lookup", [])
	_curve = []
	if lookup is Array:
		for entry: Variant in lookup:
			if entry is Array and (entry as Array).size() >= 2:
				_curve.append([float((entry as Array)[0]),
					str((entry as Array)[1])])
	if _curve.is_empty():
		# Without the curve, a plain dusk-to-dawn night.
		_curve = [[0.0, "night"], [0.2, "identity"], [0.45, "night"],
			[0.55, "night"], [0.8, "identity"], [1.0, "night"]]


func tick() -> void:
	if enabled:
		time_of_day = fmod(time_of_day + 1.0 / float(TICKS_PER_DAY), 1.0)


## How dark the world is, from 0 for broad daylight to 1 for the dead of night.
##
## The curve is a list of named tables rather than numbers, so it is read as a
## step function and smoothed between the two entries that bracket the time.
func darkness() -> float:
	if _curve.is_empty():
		return 0.0
	var previous: Array = _curve[_curve.size() - 1]
	var next: Array = _curve[0]
	for entry: Array in _curve:
		if float(entry[0]) <= time_of_day:
			previous = entry
		else:
			next = entry
			break
	var span := float(next[0]) - float(previous[0])
	while span < 0.0:
		span += 1.0
	var along := 0.0
	if span > 0.0001:
		along = fmod(time_of_day - float(previous[0]) + 1.0, 1.0) / span
	var from := _weight(str(previous[1]))
	var to := _weight(str(next[1]))
	var value := lerpf(from, to, clampf(along, 0.0, 1.0))
	if night_vision:
		# Night vision does not turn the night off, it lifts the floor.
		value = minf(value, 0.35)
	return clampf(value, 0.0, 1.0)


## A named colour table as a number: `identity` is day, anything else night.
static func _weight(name: String) -> float:
	return 0.0 if name == "identity" or name.is_empty() else 1.0


## The colour laid over the world, the same sky-blue night Factorio uses.
func tint() -> Color:
	var dark := darkness()
	if is_zero_approx(dark):
		return Color(1, 1, 1, 0)
	# Factorio's night table is a desaturated blue that keeps some detail,
	# rather than a flat black.
	var sky := Color(0.16, 0.22, 0.42)
	return Color(sky.r, sky.g, sky.b, dark * 0.85)


## Whether it is dark enough for the lamps and the biters' habits to matter.
func is_night() -> bool:
	return darkness() >= 0.5


func stats() -> Dictionary:
	return {"time_of_day": time_of_day, "darkness": darkness(),
		"night": is_night(), "night_vision": night_vision,
		"curve_points": _curve.size()}


func to_dict() -> Dictionary:
	return {"time_of_day": time_of_day, "enabled": enabled}


func from_dict(data: Dictionary) -> void:
	time_of_day = float(data.get("time_of_day", 0.25))
	enabled = bool(data.get("enabled", true))
