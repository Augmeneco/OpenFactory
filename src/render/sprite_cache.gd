class_name SpriteCache
extends RefCounted
## Memoised ``SpriteSource.resolve`` results.
##
## Resolving a graphics node walks a tree of dictionaries and builds atlas
## regions, which is far too slow to repeat for every entity every frame.
## Entity visuals only depend on (prototype, node, direction, frame,
## variation), so callers pass a stable ``tag`` describing the prototype and
## which of its graphics nodes is being resolved.

static var _cache: Dictionary = {}


static func layers(graphics: Variant, direction := 0, frame := 0,
		variation := 0, tag := "") -> Array:
	return _fetch(graphics, direction, frame, variation, tag, false)


## Same, but ``row`` is a sprite sheet row rather than a rotation (belts).
static func layers_row(graphics: Variant, row := 0, frame := 0,
		variation := 0, tag := "") -> Array:
	return _fetch(graphics, row, frame, variation, tag, true)


static func _fetch(graphics: Variant, direction: int, frame: int, variation: int,
		tag: String, as_row: bool) -> Array:
	if graphics == null:
		return []
	var key := "%s|%d|%d|%d|%s" % [tag if not tag.is_empty() else _content_key(graphics),
		direction, frame, variation, "row" if as_row else "dir"]
	var hit: Variant = _cache.get(key)
	if hit != null:
		return hit
	var resolved: Array = SpriteSource.resolve_row(graphics, direction, frame, variation) \
		if as_row else SpriteSource.resolve(graphics, direction, frame, variation)
	_cache[key] = resolved
	return resolved


## Fallback identity for callers without a tag: a structural fingerprint that
## includes values, so two different sprite nodes never collide.
static func _content_key(value: Variant, depth := 0) -> String:
	if depth > 6:
		return "..."
	if value is Dictionary:
		var parts := PackedStringArray()
		var keys: Array = value.keys()
		keys.sort()
		for key: Variant in keys:
			parts.append("%s=%s" % [key, _content_key(value[key], depth + 1)])
		return "{" + ",".join(parts) + "}"
	if value is Array:
		var parts2 := PackedStringArray()
		for entry: Variant in value:
			parts2.append(_content_key(entry, depth + 1))
		return "[" + ",".join(parts2) + "]"
	return str(value)


static func clear() -> void:
	_cache.clear()


static func size() -> int:
	return _cache.size()
