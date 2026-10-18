class_name TileAtlas
extends RefCounted
## Resolves a tile prototype into concrete screen rectangles.
##
## A tile prototype carries ``variants.main``: entries that each provide
## ``count`` interchangeable pictures covering ``size`` x ``size`` tiles.  The
## pictures sit in one packed atlas, laid out left to right with ``line_length``
## entries per row starting at pixel offset ``y``.  One tile is 64 source pixels
## (Factorio ships 2x artwork that renders at ``scale`` 0.5).
##
## Only ``size == 1`` entries are used for the base ground layer; the larger
## entries are multi-tile decorations that need transition handling.

const SOURCE_TILE := 64

static var _variants: Dictionary = {}
static var _info: Dictionary = {}


## Raw ``size == 1`` entries of a tile, in selection order.
static func variants(tile_name: String) -> Array:
	if _variants.has(tile_name):
		return _variants[tile_name]
	var out: Array = []
	var proto := Prototypes.get_p("tile", tile_name)
	var variants: Variant = proto.get("variants", {})
	var main: Variant = (variants as Dictionary).get("main", [])
	if main is Array:
		for entry: Variant in main:
			if entry is Dictionary and int(entry.get("size", 1)) == 1:
				out.append(entry)
	if out.is_empty() and variants is Dictionary:
		# Landfill and a few other tiles have no "main" variants: their ground
		# picture lives in `material_background`.  Without this fallback a
		# landfill tile was valid for the world but drew nothing, leaving a
		# hole in the map where the water used to be.
		var background: Variant = (variants as Dictionary).get("material_background")
		if background is Dictionary:
			var entry: Dictionary = (background as Dictionary).duplicate()
			if not entry.has("line_length"):
				entry["line_length"] = maxi(1, int(entry.get("count", 1)))
			out.append(entry)
	_variants[tile_name] = out
	return out


static func is_valid(tile_name: String) -> bool:
	return not Prototypes.get_p("tile", tile_name).is_empty()


## Everything the renderer needs to blit this tile, precomputed once.
##
## Returns ``{ texture, rects: Array[Rect2], weights: PackedFloat32Array,
## pixel_size: float, frames: int, weighted: bool }`` or an empty dictionary.
static func render_info(tile_name: String) -> Dictionary:
	if _info.has(tile_name):
		return _info[tile_name]
	var entries := variants(tile_name)
	if entries.is_empty():
		_info[tile_name] = {}
		return {}

	# Prefer the entry that is always used (probability 1 / absent).
	var entry: Dictionary = entries[0]
	for candidate: Dictionary in entries:
		if float(candidate.get("probability", 1.0)) >= 1.0:
			entry = candidate
			break

	var picture := str(entry.get("picture", ""))
	var texture := FactorioAssets.texture(picture)
	if texture == null:
		_info[tile_name] = {}
		return {}

	var count := maxi(1, int(entry.get("count", 1)))
	var step := int(entry.get("size", 1)) * SOURCE_TILE
	var frames := 1
	if not entry.has("line_length"):
		# A single un-sliced picture with several columns is an animation
		# (water waves); the extra pictures are frames, not variants.
		frames = maxi(1, int(texture.get_width() / step))
		count = 1

	var rects: Array[Rect2] = []
	for i in maxi(count, frames):
		rects.append(_rect(entry, i, count, frames))

	var weights := PackedFloat32Array()
	var weighted := false
	var raw_weights: Variant = entry.get("weights")
	if raw_weights is Array and raw_weights.size() >= count:
		for i in count:
			weights.append(float(raw_weights[i]))
		weighted = true
	else:
		for i in count:
			weights.append(1.0)

	var info := {
		"texture": texture,
		"path": picture,
		"rects": rects,
		"weights": weights,
		"weighted": weighted,
		"pixel_size": SOURCE_TILE * float(entry.get("scale", 0.5)),
		"frames": frames,
	}
	_info[tile_name] = info
	return info


static func _rect(entry: Dictionary, index: int, count: int, frames: int) -> Rect2:
	var step := int(entry.get("size", 1)) * SOURCE_TILE
	var line_length := int(entry.get("line_length", 0))
	if line_length <= 0:
		line_length = count
	var col := index % line_length
	var row := index / line_length
	if frames > 1:
		# Animation frames run along the row.
		col = index
		row = 0
	return Rect2(float(col * step), float(entry.get("y", 0)) + float(row * step),
		float(step), float(step))


## Variant index for a cell, honouring per-variant weights.
static func variant_index(info: Dictionary, cell: Vector2i) -> int:
	var count: int = (info["weights"] as PackedFloat32Array).size()
	if count <= 1:
		return 0
	var roll := _hash01(cell, 0x85ebca6b)
	if info.get("weighted", false):
		var weights: PackedFloat32Array = info["weights"]
		var total := 0.0
		for w in weights:
			total += w
		if total <= 0.0:
			return 0
		var target := roll * total
		var accumulated := 0.0
		for i in count:
			accumulated += weights[i]
			if target < accumulated:
				return i
		return count - 1
	return int(roll * count) % count


## Deterministic random value in [0,1) for a cell, so a given tile always
## shows the same variant.
static func _hash01(cell: Vector2i, salt: int) -> float:
	var h := int(cell.x) * 0x1f1f1f1f ^ int(cell.y) * 0x27d4eb2d ^ salt
	h = (h ^ (h >> 15)) * 0x2545f491
	h = h ^ (h >> 13)
	return float(h & 0xffffff) / 16777216.0


static func stats() -> Dictionary:
	return {"tiles_cached": _info.size()}
