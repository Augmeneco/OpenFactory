class_name SpriteSource
extends RefCounted
## Turns Factorio graphics definitions into concrete draw instructions.
##
## Factorio describes artwork with a handful of interchangeable node shapes
## (``Sprite``, ``SpriteSheet``, ``Animation``, ``RotatedAnimation``,
## ``*Variations``), each of which may itself be a list of ``layers`` or be
## split across several ``sheets``/``filenames``.  This resolver flattens any
## of them into a list of textured rectangles for one animation state.
##
## Layout rules, derived from the shipped sprite sheets themselves:
##   * plain animation / rotated animation — rows are directions, columns are
##     frames, i.e. ``index = frame + frame_count * direction``;
##   * ``*Variations`` (a ``sheet`` holding many variations) — rows are frames,
##     columns are variations, i.e. ``index = variation + variation_count * frame``;
##   * ``line_length`` overrides the column count when set, otherwise the
##     natural column count of the shape is used.

const TILE := 32.0

## One resolved rectangle of artwork.
class Layer:
	extends RefCounted
	var texture: Texture2D
	var reference := ""          ## source path, kept for offline previews
	var src_rect := Rect2()      ## region inside the source image
	var offset := Vector2.ZERO   ## pixels from the entity centre
	var size := Vector2.ZERO     ## drawn size in pixels
	var modulate := Color.WHITE
	## Radians to turn the sprite about its centre.  Most Factorio sprites are
	## pre-rotated in their sheet, but an inserter's is not — the game turns the
	## picture itself, so the same has to happen here.
	var rotation := 0.0
	var shadow := false
	var glow := false
	## Opaque light masks need additive blending, which one batched canvas
	## cannot switch per rectangle; the renderer skips them rather than
	## painting a black box over the machine.
	var light := false
	var additive := false
	var render_layer := ""
	var priority := "medium"
	## Layer carries the player colour mask, tinted at draw time.
	var runtime_tint := false

	func duplicate_layer() -> Layer:
		var copy := Layer.new()
		copy.texture = texture
		copy.reference = reference
		copy.src_rect = src_rect
		copy.offset = offset
		copy.size = size
		copy.modulate = modulate
		copy.shadow = shadow
		copy.glow = glow
		copy.light = light
		copy.additive = additive
		copy.render_layer = render_layer
		copy.priority = priority
		copy.runtime_tint = runtime_tint
		return copy


## Resolve ``graphics`` for one animation state into a flat list of layers.
##
## ``direction`` is a ``defines.direction`` value (0..15) and is mapped onto
## however many rotations the sheet actually holds — a 4-way entity given
## ``east`` (4) picks row 1, an 8-way entity picks row 2.  ``variation``
## selects a random visual variant and ``frame`` an animation frame.
static func resolve(graphics: Variant, direction := 0, frame := 0,
		variation := 0) -> Array[Layer]:
	var out: Array[Layer] = []
	_resolve(graphics, {}, direction, frame, variation, false, out, false)
	return out


## Like ``resolve`` but ``row`` is used verbatim as the sprite sheet row.
##
## Belts need this: their 20 "directions" are connection shapes (straight,
## curve, junction, end), not rotations.
static func resolve_row(graphics: Variant, row := 0, frame := 0,
		variation := 0) -> Array[Layer]:
	var out: Array[Layer] = []
	_resolve(graphics, {}, row, frame, variation, false, out, true)
	return out


## Row index a ``defines.direction`` value maps to on a sheet with
## ``direction_count`` rotations.
static func row_for(direction: int, direction_count: int) -> int:
	if direction_count <= 1:
		return 0
	return posmod(int(round(float(direction) * float(direction_count) / 16.0)),
		direction_count)


static func _resolve(node: Variant, ctx: Dictionary, direction: int, frame: int,
		variation: int, in_variations: bool, out: Array[Layer],
		as_row := false) -> void:
	if node == null:
		return
	if node is Array:
		for entry in node:
			_resolve(entry, ctx, direction, frame, variation, in_variations, out, as_row)
		return
	if not (node is Dictionary):
		return

	var local := _context(node, ctx)

	# Rails and other direction-indexed strips store one animation per direction.
	if node.has("stripes"):
		var stripes: Array = node["stripes"]
		if not stripes.is_empty():
			var pick := posmod(direction, stripes.size())
			_resolve(stripes[pick], local, direction, frame, variation, in_variations, out, as_row)
		return

	# ``sheet`` is the single-sheet shorthand of the *Variations wrappers.
	if node.has("sheet"):
		_resolve(node["sheet"], local, direction, frame, variation, true, out, as_row)
		return

	if node.has("sheets"):
		var sheets: Array = node["sheets"]
		if _sheets_are_variations(node, sheets):
			_emit_variation_sheets(sheets, local, direction, frame, variation, out, as_row)
		else:
			for sheet in sheets:
				_resolve(sheet, local, direction, frame, variation, in_variations, out, as_row)
		return

	# ``layers`` lists parallel sprite layers of one object.
	if node.has("layers"):
		for layer in node["layers"]:
			_resolve(layer, local, direction, frame, variation, in_variations, out, as_row)
		return

	if node.has("filenames"):
		_emit_multi_file(node, local, direction, frame, variation, in_variations, out, as_row)
		return

	if node.has("filename"):
		_emit_sprite(node, local, direction, frame, variation, in_variations, out, as_row)


# --------------------------------------------------------------------------
# context handling
# --------------------------------------------------------------------------

static func _context(node: Dictionary, parent: Dictionary) -> Dictionary:
	var ctx := parent.duplicate()
	for key in ["frame_count", "direction_count", "variation_count", "line_length"]:
		if node.has(key):
			ctx[key] = int(node[key])
	if node.has("shift"):
		ctx["shift"] = FactorioAssets.parse_vector(node["shift"])
	if node.has("scale"):
		ctx["scale"] = float(node["scale"])
	if node.has("tint"):
		ctx["tint"] = FactorioAssets.parse_color(node["tint"])
	if node.has("draw_as_shadow"):
		ctx["shadow"] = bool(node["draw_as_shadow"])
	if node.has("draw_as_glow"):
		ctx["glow"] = bool(node["draw_as_glow"])
	if node.has("draw_as_light"):
		ctx["light"] = bool(node["draw_as_light"])
	if node.has("blend_mode"):
		ctx["additive"] = str(node["blend_mode"]) == "additive"
	if node.has("apply_runtime_tint"):
		ctx["runtime_tint"] = bool(node["apply_runtime_tint"])
	if node.has("render_layer"):
		ctx["render_layer"] = str(node["render_layer"])
	if node.has("priority"):
		ctx["priority"] = str(node["priority"])
	return ctx


static func _int(ctx: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = ctx.get(key)
	if value == null:
		return fallback
	return maxi(1, int(value))


static func _sheet_columns(ctx: Dictionary, frame_count: int, variation_count: int,
		total: int, in_variations: bool) -> int:
	var line_length := int(ctx.get("line_length", 0))
	if line_length > 0:
		return line_length
	if in_variations and variation_count > 1:
		return variation_count
	if frame_count > 1:
		return frame_count
	if variation_count > 1:
		return variation_count
	return maxi(1, total)


## Index of a sprite inside a sheet, following the layout rules above.
static func _sprite_index(frame_count: int, direction_count: int, variation_count: int,
		direction: int, frame: int, variation: int, in_variations: bool,
		as_row := false) -> int:
	var d := posmod(direction, direction_count) if as_row \
		else row_for(direction, direction_count)
	if in_variations:
		var v := posmod(variation, variation_count)
		var f := posmod(frame, frame_count)
		return v + variation_count * (f + frame_count * d)
	var f2 := posmod(frame, frame_count)
	var v2 := posmod(variation, variation_count)
	return f2 + frame_count * (d + direction_count * v2)


# --------------------------------------------------------------------------
# emitters
# --------------------------------------------------------------------------

static func _emit_sprite(node: Dictionary, ctx: Dictionary, direction: int, frame: int,
		variation: int, in_variations: bool, out: Array[Layer],
		as_row := false) -> void:
	var reference := str(node["filename"])
	var texture := FactorioAssets.texture(reference)
	if texture == null:
		return

	var image_size := Vector2(texture.get_width(), texture.get_height())
	var frame_count := _int(ctx, "frame_count", 1)
	var direction_count := _int(ctx, "direction_count", 1)
	var variation_count := _int(ctx, "variation_count", 1)

	var sprite_size := _sprite_size(node, ctx, image_size)
	var sprite_w := sprite_size.x
	var sprite_h := sprite_size.y
	if sprite_w <= 0.0 or sprite_h <= 0.0:
		return

	var cols := maxi(1, int(image_size.x / sprite_w))
	var rows := maxi(1, int(image_size.y / sprite_h))
	var total := cols * rows
	cols = _sheet_columns(ctx, frame_count, variation_count, total, in_variations)

	var index := _sprite_index(frame_count, direction_count, variation_count,
		direction, frame, variation, in_variations, as_row)
	if index >= total:
		index = index % total

	var col := index % cols
	var row := index / cols
	var origin := Vector2(float(node.get("x", 0)), float(node.get("y", 0)))
	var rect := Rect2(origin + Vector2(col * sprite_w, row * sprite_h),
		Vector2(sprite_w, sprite_h))

	var scale := float(ctx.get("scale", 1.0))
	var shift: Vector2 = ctx.get("shift", Vector2.ZERO)

	var layer := Layer.new()
	# Hand out the *whole* sheet and let the `src_rect` below pick the frame.
	# Wrapping the slice in an AtlasTexture as well made the renderer apply the
	# region twice: every sprite whose frame is not at the sheet's origin was
	# sampled from `region + src_rect`.  That double offset is what hid the
	# engineer (its idle sheet starts at y=464, so the second offset landed
	# outside the texture) and drew belts with rows from the wrong place.
	layer.texture = texture
	layer.reference = reference
	layer.src_rect = rect
	layer.size = Vector2(sprite_w, sprite_h) * scale
	layer.offset = shift * TILE
	layer.modulate = ctx.get("tint", Color.WHITE)
	layer.shadow = bool(ctx.get("shadow", false))
	layer.glow = bool(ctx.get("glow", false))
	layer.light = bool(ctx.get("light", false))
	layer.additive = bool(ctx.get("additive", false))
	layer.render_layer = str(ctx.get("render_layer", ""))
	layer.priority = str(ctx.get("priority", "medium"))
	layer.runtime_tint = bool(ctx.get("runtime_tint", false))
	if layer.texture != null:
		out.append(layer)


## Sheets that together hold a set of variations; each sheet covers a slice.
static func _emit_variation_sheets(sheets: Array, ctx: Dictionary, direction: int,
		frame: int, variation: int, out: Array[Layer], as_row := false) -> void:
	if sheets.size() == 1:
		_resolve(sheets[0], ctx, direction, frame, variation, true, out, as_row)
		return
	# Distribute variations across sheets in order, the way Factorio packs a
	# big variation set over several files.
	var per_sheet := 1
	for sheet in sheets:
		if sheet is Dictionary and sheet.has("variation_count"):
			per_sheet = maxi(per_sheet, int(sheet["variation_count"]))
	var index := posmod(variation, maxi(1, sheets.size() * per_sheet))
	var picked := index / per_sheet
	var local_variation := index % per_sheet
	if picked >= sheets.size():
		picked = sheets.size() - 1
	_resolve(sheets[picked], ctx, direction, frame, local_variation, true, out, as_row)


static func _sheets_are_variations(node: Dictionary, sheets: Array) -> bool:
	if node.has("variation_count") and int(node["variation_count"]) > 1:
		return true
	for sheet in sheets:
		if sheet is Dictionary and sheet.has("variation_count"):
			return true
	return false


## ``filenames`` splits one logical sheet across several files.
static func _emit_multi_file(node: Dictionary, ctx: Dictionary, direction: int,
		frame: int, variation: int, in_variations: bool, out: Array[Layer],
		as_row := false) -> void:
	var filenames: Array = node["filenames"]
	if filenames.is_empty():
		return
	var lines_per_file := maxi(1, int(node.get("lines_per_file", 1)))
	var frame_count := _int(ctx, "frame_count", 1)
	var direction_count := _int(ctx, "direction_count", 1)
	var variation_count := _int(ctx, "variation_count", 1)
	var slice := int(node.get("slice", frame_count))

	var per_file := maxi(1, slice * direction_count * variation_count)
	var index := _sprite_index(frame_count, direction_count, variation_count,
		direction, frame, variation, in_variations, as_row)
	var file_index := index / per_file
	if file_index >= filenames.size():
		file_index = filenames.size() - 1

	var single := node.duplicate()
	single.erase("filenames")
	single.erase("lines_per_file")
	single["filename"] = filenames[file_index]
	single["frame_count"] = slice
	single["line_length"] = int(node.get("line_length", slice))
	var local := ctx.duplicate()
	local["frame_count"] = slice
	if node.has("direction_count"):
		local["direction_count"] = direction_count
	var local_index := index % per_file
	var local_frame := local_index % slice
	var local_dir := (local_index / slice) % maxi(1, direction_count)
	var local_var := local_index / maxi(1, slice * direction_count)
	_emit_sprite(single, local, local_dir, local_frame, local_var, in_variations, out, true)
	# Silence the unused warning while keeping the intent explicit.
	if lines_per_file < 0:
		push_warning("unreachable")


static func _sprite_size(node: Dictionary, ctx: Dictionary, image_size: Vector2) -> Vector2:
	if node.has("size"):
		var size: Variant = node["size"]
		if size is Array and size.size() >= 2:
			return Vector2(float(size[0]), float(size[1]))
		if size is Dictionary:
			return FactorioAssets.parse_vector(size)
		if size is float or size is int:
			return Vector2(float(size), float(size))
	# Character shadows are packed as a fixed grid inside one file.
	if node.has("width_in_frames") and node.has("height_in_frames"):
		return Vector2(
			image_size.x / maxf(float(node["width_in_frames"]), 1.0),
			image_size.y / maxf(float(node["height_in_frames"]), 1.0))
	if node.has("width") and node.has("height"):
		return Vector2(float(node["width"]), float(node["height"]))
	if ctx.has("width") and ctx.has("height"):
		return Vector2(float(ctx["width"]), float(ctx["height"]))
	return image_size


# --------------------------------------------------------------------------
# convenience helpers for entity prototypes
# --------------------------------------------------------------------------

## Pick the graphics node an entity of ``proto`` uses when standing still.
static func idle_graphics(proto: Dictionary) -> Variant:
	for key in ["pictures", "picture", "animation", "animations", "graphics_set"]:
		if proto.has(key):
			return proto[key]
	return null


## Factorio's 16 direction names, indexed by enum value.
const DIRECTION_NAMES := [
	"north", "northnortheast", "northeast", "eastnortheast",
	"east", "eastsoutheast", "southeast", "southsoutheast",
	"south", "southsouthwest", "southwest", "westsouthwest",
	"west", "westnorthwest", "northwest", "northnorthwest",
]


## Several entities key their artwork by direction name
## (``graphics_set.animation.north``).  Snap to the nearest available key so a
## 4-way entity still resolves when asked for an 8- or 16-way direction.
static func direction_entry(node: Variant, direction: int) -> Variant:
	if not (node is Dictionary):
		return null
	for step in range(16):
		for offset in ([0] if step == 0 else [step, -step]):
			var candidate: String = DIRECTION_NAMES[posmod(direction + offset, 16)]
			if node.has(candidate):
				return node[candidate]
	return null


## A deterministic variation index for a world position, so the same tile
## always shows the same variant (matching Factorio's behaviour).
static func variation_for(cell: Vector2i, variation_count: int) -> int:
	if variation_count <= 1:
		return 0
	var h := int(cell.x) * 73856093 ^ int(cell.y) * 19349663
	return posmod(h, variation_count)
