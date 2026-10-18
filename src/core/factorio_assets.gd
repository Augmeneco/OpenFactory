extends Node
## Runtime access to Factorio's own artwork.
##
## Rather than copying (and re-importing) ~1.3 GB of PNGs, sprites are read
## straight out of the Factorio installation by resolving the ``__mod__/path``
## references found in prototype data.  Images are decoded once and cached as
## ``ImageTexture``; slices are handed out as ``AtlasTexture`` regions so the
## renderer can batch them with ``draw_texture_rect_region``.

## Pixel size of one map tile, as Factorio uses it.
const TILE_PIXELS := 32

var root: String = ""          ## Factorio install root
var data_path: String = ""     ## <root>/data

var _images: Dictionary = {}      ## abs path -> Image
var _textures: Dictionary = {}    ## abs path -> ImageTexture
var _missing: Dictionary = {}     ## abs path -> true (reported once)
var _composed: Dictionary = {}    ## cache key -> ImageTexture

## Bytes of decoded image data currently held, for diagnostics.
var resident_bytes: int = 0

signal load_failed(reference: String)


func _ready() -> void:
	root = Prototypes.factorio_root
	data_path = Prototypes.data_path
	if not DirAccess.dir_exists_absolute(data_path):
		push_error("Assets: Factorio data path does not exist: " + data_path)


# --------------------------------------------------------------------------
# path resolution
# --------------------------------------------------------------------------

## ``__base__/graphics/entity/belt.png`` -> absolute path on disk.
func resolve(reference: String) -> String:
	if reference.begins_with("res://") or reference.begins_with("/"):
		return reference
	if reference.begins_with("__"):
		var slash := reference.find("/")
		if slash == -1:
			return ""
		var mod := reference.substr(2, slash - 2).trim_suffix("__")
		return data_path.path_join(mod).path_join(reference.substr(slash + 1))
	return data_path.path_join(reference)


## Actual file for a reference.  Packaged builds rename art/audio to ``.bin``
## so Godot does not try to import ~1.5 GB of PNGs as resources; the original
## suffix is kept inside the code's decoder.
func packed_file(path: String) -> String:
	if path.is_empty():
		return ""
	if FileAccess.file_exists(path):
		return path
	var packed := path + ".bin"
	if FileAccess.file_exists(packed):
		return packed
	return ""


func exists(reference: String) -> bool:
	var path := resolve(reference)
	return not packed_file(path).is_empty()


# --------------------------------------------------------------------------
# image / texture loading
# --------------------------------------------------------------------------

func image(reference: String) -> Image:
	var path := resolve(reference)
	if path.is_empty():
		return null
	if _images.has(path):
		return _images[path]
	if _missing.has(path):
		return null
	var source := packed_file(path)
	if source.is_empty():
		_missing[path] = true
		push_warning("Assets: missing file " + path)
		load_failed.emit(reference)
		return null
	var img := _load_image(source, path)
	if img == null:
		_missing[path] = true
		push_warning("Assets: could not decode " + path)
		load_failed.emit(reference)
		return null
	_images[path] = img
	resident_bytes += img.get_width() * img.get_height() * _bytes_per_pixel(img)
	return img


func texture(reference: String) -> ImageTexture:
	var path := resolve(reference)
	if path.is_empty():
		return null
	if _textures.has(path):
		return _textures[path]
	var img := image(reference)
	if img == null:
		return null
	var tex := ImageTexture.create_from_image(img)
	_textures[path] = tex
	return tex


## Read PNG/JPG/WebP bytes through FileAccess.  ``Image.load_from_file`` only
## works on real filesystem files, while an exported build stores the bundled
## Factorio data inside the PCK as ``res://`` entries.
func _load_image(source: String, original_path: String) -> Image:
	if source.begins_with("res://") or source.begins_with("user://"):
		var bytes := FileAccess.get_file_as_bytes(source)
		if bytes.is_empty():
			return null
		var image := Image.new()
		var extension := original_path.get_extension().to_lower()
		var error := ERR_FILE_UNRECOGNIZED
		match extension:
			"png":
				error = image.load_png_from_buffer(bytes)
			"jpg", "jpeg":
				error = image.load_jpg_from_buffer(bytes)
			"webp":
				error = image.load_webp_from_buffer(bytes)
			"bmp":
				error = image.load_bmp_from_buffer(bytes)
			"tga":
				error = image.load_tga_from_buffer(bytes)
			_:
				error = ERR_FILE_UNRECOGNIZED
		return image if error == OK else null
	return Image.load_from_file(source)


static func _bytes_per_pixel(img: Image) -> int:
	match img.get_format():
		Image.FORMAT_RGBA8, Image.FORMAT_RGBAF:
			return 4
		Image.FORMAT_RGB8:
			return 3
		Image.FORMAT_L8, Image.FORMAT_R8:
			return 1
		_:
			return 4


## A sub-rectangle of a texture, ready for ``draw_texture_rect_region``.
func region(reference: String, rect: Rect2) -> AtlasTexture:
	var path := resolve(reference)
	if path.is_empty():
		return null
	var key := "%s|%.1f,%.1f,%.1f,%.1f" % [path, rect.position.x, rect.position.y,
		rect.size.x, rect.size.y]
	if _composed.has(key):
		return _composed[key]
	var tex := texture(reference)
	if tex == null:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = rect
	atlas.filter_clip = true
	_composed[key] = atlas
	return atlas


# --------------------------------------------------------------------------
# icon composition
# --------------------------------------------------------------------------

## Build the finished inventory icon for a prototype.
##
## Factorio's ``icons`` array layers several images with individual tints,
## scales and shifts on top of a base layer; ``icon`` is the single-image
## shorthand.  Every icon file also carries its own mipmap chain to the right
## of the full-size square (64+32+16+8 = 120 px wide), so only the first
## ``icon_size`` square is used.  Returns ``null`` when a prototype has no
## artwork at all.
func prototype_icon(proto: Dictionary, output_size := 64) -> Texture2D:
	if proto.is_empty():
		return null

	var default_size := int(proto.get("icon_size", 64))
	var layers: Array = []
	if proto.has("icon"):
		layers = [{"icon": proto["icon"], "icon_size": default_size}]
	else:
		layers = proto.get("icons", [])
	if layers.is_empty():
		return null

	var key := "icon:%s|%s|%d" % [str(proto.get("type", "")), str(proto.get("name", "")), output_size]
	if _composed.has(key):
		return _composed[key]

	var canvas := Image.create(output_size, output_size, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0, 0, 0, 0))

	# draw_background layers form the plate; the rest stack on top of it.
	var background: Array = []
	var foreground: Array = []
	for entry in layers:
		if entry is Dictionary and bool(entry.get("draw_background", false)):
			background.append(entry)
		else:
			foreground.append(entry)

	for entry: Variant in background + foreground:
		_compose_icon_layer(canvas, entry, default_size, output_size)

	var tex := ImageTexture.create_from_image(canvas)
	_composed[key] = tex
	return tex


func _compose_icon_layer(canvas: Image, entry: Dictionary, default_icon_size: int,
		output_size: int) -> void:
	var reference := str(entry.get("icon", ""))
	if reference.is_empty():
		return
	var sheet := image(reference)
	if sheet == null:
		return

	# Icon files store the full-size square first, then its mipmaps.
	var icon_size := int(entry.get("icon_size", default_icon_size))
	icon_size = mini(icon_size, mini(sheet.get_width(), sheet.get_height()))
	var layer := sheet.get_region(Rect2i(0, 0, icon_size, icon_size))

	var scale := float(entry.get("scale", 1.0)) * float(output_size) / float(icon_size)
	var target := Vector2i(
		maxi(1, int(round(icon_size * scale))),
		maxi(1, int(round(icon_size * scale))))
	if layer.get_width() != target.x or layer.get_height() != target.y:
		layer.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)

	var tint: Color = _parse_color(entry.get("tint", null), Color(1, 1, 1, 1))
	var shift: Vector2 = _parse_vector(entry.get("shift", null)) * scale
	var origin := Vector2i(
		int(round((output_size - target.x) * 0.5 + shift.x)),
		int(round((output_size - target.y) * 0.5 + shift.y)))

	_blit(canvas, layer, origin, tint, 1.0)


## Blend ``src`` onto ``dst`` at ``origin``, multiplying by ``tint``.
static func _blit(dst: Image, src: Image, origin: Vector2i, tint: Color, _alpha: float) -> void:
	for y in src.get_height():
		var dy := origin.y + y
		if dy < 0 or dy >= dst.get_height():
			continue
		for x in src.get_width():
			var dx := origin.x + x
			if dx < 0 or dx >= dst.get_width():
				continue
			var s := src.get_pixel(x, y) * tint
			if s.a <= 0.0:
				continue
			dst.set_pixel(dx, dy, dst.get_pixel(dx, dy).blend(s))


# --------------------------------------------------------------------------
# small parsers for Factorio's shorthand value shapes
# --------------------------------------------------------------------------

## Factorio writes colours as ``{r,g,b,a}`` tables; Godot's JSON gives us a
## Dictionary that has to be converted.
static func parse_color(value: Variant, fallback: Color = Color.WHITE) -> Color:
	return _parse_color(value, fallback)


static func _parse_color(value: Variant, fallback: Color) -> Color:
	if value == null:
		return fallback
	if value is String:
		return Color.from_string(value, fallback)
	if value is Dictionary:
		return Color(
			float(value.get("r", 1.0)), float(value.get("g", 1.0)),
			float(value.get("b", 1.0)), float(value.get("a", 1.0)))
	if value is Array and value.size() >= 3:
		return Color(float(value[0]), float(value[1]), float(value[2]),
			float(value[3]) if value.size() > 3 else 1.0)
	return fallback


## Factorio writes vectors as ``{x,y}`` or ``[x,y]``.
static func parse_vector(value: Variant, fallback := Vector2.ZERO) -> Vector2:
	return _parse_vector(value, fallback)


static func _parse_vector(value: Variant, fallback := Vector2.ZERO) -> Vector2:
	if value == null:
		return fallback
	if value is Dictionary:
		return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


## Bounding boxes are ``{{x1,y1},{x2,y2}}``.
static func parse_box(value: Variant, fallback: Rect2 = Rect2()) -> Rect2:
	if value is Array and value.size() == 2:
		var a := _parse_vector(value[0])
		var b := _parse_vector(value[1])
		return Rect2(a, b - a)
	return fallback


func stats() -> Dictionary:
	return {
		"images": _images.size(),
		"textures": _textures.size(),
		"missing": _missing.size(),
		"resident_mb": resident_bytes / 1048576.0,
	}


## Icon for a recipe: its own artwork when it has any, otherwise the icon of
## its main product — the rule Factorio itself uses.
func recipe_icon(recipe: Dictionary, output_size := 64) -> Texture2D:
	if recipe.is_empty():
		return null
	if recipe.has("icon") or recipe.has("icons"):
		return prototype_icon(recipe, output_size)
	for product: Dictionary in Prototypes.recipe_products(recipe):
		var proto := Prototypes.item_proto(str(product.get("name", "")))
		if proto.is_empty():
			proto = Prototypes.get_p(str(product.get("type", "item")),
				str(product.get("name", "")))
		if not proto.is_empty():
			return prototype_icon(proto, output_size)
	return null


## Icon for any prototype type, falling back to the recipe rule for recipes.
func icon_for(proto_type: String, proto_name: String, output_size := 64) -> Texture2D:
	if proto_type == "recipe":
		return recipe_icon(Prototypes.get_p("recipe", proto_name), output_size)
	if proto_type == "item":
		return prototype_icon(Prototypes.item_proto(proto_name), output_size)
	return prototype_icon(Prototypes.get_p(proto_type, proto_name), output_size)
