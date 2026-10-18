class_name Statistics
extends RefCounted
## What the factory has made and eaten, for the production screen.
##
## Factorio shows a rate per minute over a rolling window, so that is what is
## kept: a running total per item for the session, and a ring of one-second
## buckets covering the last minute.  Counting every item every tick would be
## pointless; a second's resolution is what the display can actually show.

## How many one-second buckets the one-minute window holds.
const WINDOW_SECONDS := 60

## The ranges the graph can show, each as sixty buckets of its own width.
##
## One resolution is not enough for a graph: a minute of seconds answers "what
## just happened", an hour of minutes answers "is this line growing", and both
## are the same picture at different zoom.
const RANGES := [
	{"key": "1m", "seconds": 60, "bucket": 1},
	{"key": "10m", "seconds": 600, "bucket": 10},
	{"key": "1h", "seconds": 3600, "bucket": 60},
]
const BUCKETS := 60

var produced: Dictionary = {}        ## item -> total for the session
var consumed: Dictionary = {}
## range key -> item -> Array of BUCKETS counts, oldest slot reused first.
var _produced_history: Dictionary = {}
var _consumed_history: Dictionary = {}
## range key -> the slot last written, so a slot is cleared exactly once.
var _last_slot: Dictionary = {}
var _last_second := -1
## How many seconds the window actually covers, which is less than a minute
## until the factory has been running for one.
var _covered := 0


func record_produced(item_name: String, amount: int) -> void:
	if item_name.is_empty() or amount <= 0:
		return
	produced[item_name] = int(produced.get(item_name, 0)) + amount
	_bump(_produced_history, item_name, amount)


func record_consumed(item_name: String, amount: int) -> void:
	if item_name.is_empty() or amount <= 0:
		return
	consumed[item_name] = int(consumed.get(item_name, 0)) + amount
	_bump(_consumed_history, item_name, amount)


func _bump(window: Dictionary, item_name: String, amount: int) -> void:
	# Every range is written at once, so the graph can switch zoom without the
	# numbers changing underneath it.
	for range: Dictionary in RANGES:
		var key := str(range["key"])
		var store: Dictionary = window.get(key, {})
		window[key] = store
		var buckets: Array = store.get(item_name, [])
		if buckets.is_empty():
			buckets.resize(BUCKETS)
			buckets.fill(0)
			store[item_name] = buckets
		var slot := _slot_for(range)
		buckets[slot] = int(buckets[slot]) + amount


## Which of a range's sixty buckets the current second belongs to.
func _slot_for(range: Dictionary) -> int:
	var bucket := maxi(1, int(range["bucket"]))
	return (maxi(0, _last_second) / bucket) % BUCKETS


## Called once a second by the simulation, which is what moves the window on.
func advance(tick: int) -> void:
	var second := tick / 60
	if second == _last_second:
		return
	_last_second = second
	_covered = mini(WINDOW_SECONDS, _covered + 1)
	# The slot about to be reused is a whole range old, so it is cleared.
	for range: Dictionary in RANGES:
		var key := str(range["key"])
		var slot := _slot_for(range)
		if int(_last_slot.get(key, -1)) == slot:
			continue
		_last_slot[key] = slot
		for window: Dictionary in [_produced_history, _consumed_history]:
			var store: Variant = window.get(key, {})
			if not (store is Dictionary):
				continue
			for item_name: String in store:
				(store[item_name] as Array)[slot] = 0


## Items per minute over the last minute for one item.
func produced_per_minute(item_name: String, range_key := "1m") -> float:
	return _rate(_produced_history, item_name, range_key)


func consumed_per_minute(item_name: String, range_key := "1m") -> float:
	return _rate(_consumed_history, item_name, range_key)


func _rate(window: Dictionary, item_name: String, range_key: String) -> float:
	var buckets: Variant = _series(window, item_name, range_key)
	if not (buckets is Array) or (buckets as Array).is_empty():
		return 0.0
	var total := 0
	for value: Variant in buckets:
		total += int(value)
	var range := _range(range_key)
	var seconds := mini(float(range["seconds"]), float(_covered))
	if seconds <= 0.0:
		return 0.0
	return float(total) * 60.0 / seconds


static func _range(range_key: String) -> Dictionary:
	for range: Dictionary in RANGES:
		if str(range["key"]) == range_key:
			return range
	return RANGES[0]


## One range's buckets in reading order, oldest first.
func _series(window: Dictionary, item_name: String, range_key: String) -> Array:
	var store: Variant = window.get(range_key, {})
	if not (store is Dictionary):
		return []
	var buckets: Variant = (store as Dictionary).get(item_name, null)
	if not (buckets is Array) or (buckets as Array).is_empty():
		return []
	var slot := _slot_for(_range(range_key))
	var out: Array = []
	for offset in BUCKETS:
		out.append(int((buckets as Array)[(slot + 1 + offset) % BUCKETS]))
	return out


## The graph's line for one item: produced or consumed, over one range.
func produced_series(item_name: String, range_key := "1m") -> Array:
	return _series(_produced_history, item_name, range_key)


func consumed_series(item_name: String, range_key := "1m") -> Array:
	return _series(_consumed_history, item_name, range_key)


## The busiest item in a range, which is what the graph opens on.
func busiest(range_key := "1m") -> String:
	var best := ""
	var best_total := -1.0
	for item_name: String in produced:
		var total := produced_per_minute(item_name, range_key) \
			+ consumed_per_minute(item_name, range_key)
		if total > best_total:
			best_total = total
			best = item_name
	for item_name: String in consumed:
		if not produced.has(item_name):
			var total := consumed_per_minute(item_name, range_key)
			if total > best_total:
				best_total = total
				best = item_name
	return best


## Every item the factory has touched, busiest first, as
## ``[{ name, produced, consumed, net }]`` — rates per minute and session
## totals both.
func rows() -> Array:
	var seen: Dictionary = {}
	for item_name: String in produced:
		seen[item_name] = true
	for item_name: String in consumed:
		seen[item_name] = true
	var out: Array = []
	for item_name: String in seen:
		var made := produced_per_minute(item_name)
		var used := consumed_per_minute(item_name)
		out.append({
			"name": item_name,
			"produced": made,
			"consumed": used,
			"net": made - used,
			"total_produced": int(produced.get(item_name, 0)),
			"total_consumed": int(consumed.get(item_name, 0)),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left := maxf(float(a["produced"]), float(a["consumed"]))
		var right := maxf(float(b["produced"]), float(b["consumed"]))
		if not is_equal_approx(left, right):
			return left > right
		return str(a["name"]) < str(b["name"]))
	return out


func totals() -> Dictionary:
	var made := 0
	for value: Variant in produced.values():
		made += int(value)
	var used := 0
	for value: Variant in consumed.values():
		used += int(value)
	return {"items_produced": made, "items_consumed": used,
		"kinds": produced.size() + consumed.size()}


func clear() -> void:
	produced.clear()
	consumed.clear()
	_produced_history.clear()
	_consumed_history.clear()
	_last_slot.clear()
	_last_second = -1
	_covered = 0


func to_dict() -> Dictionary:
	return {"produced": produced.duplicate(), "consumed": consumed.duplicate(),
		"produced_history": _produced_history.duplicate(true),
		"consumed_history": _consumed_history.duplicate(true),
		"last_second": _last_second, "covered": _covered}


func from_dict(data: Dictionary) -> void:
	clear()
	produced = (data.get("produced", {}) as Dictionary).duplicate()
	consumed = (data.get("consumed", {}) as Dictionary).duplicate()
	_produced_history = (data.get("produced_history", {}) as Dictionary).duplicate(true)
	_consumed_history = (data.get("consumed_history", {}) as Dictionary).duplicate(true)
	_last_second = int(data.get("last_second", -1))
	_covered = int(data.get("covered", 0))
