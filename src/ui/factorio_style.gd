extends Node
## Factorio's GUI stylesheet, turned into Godot theme resources.
##
## ``data.raw["gui-style"]["default"]`` contains every widget Factorio draws:
## frames, buttons, slots, progress bars, tooltips — roughly nine hundred named
## styles, each with per-state 9-slice sprites and paddings.  This service
## resolves the ``parent`` inheritance chain and converts the sprites into
## ``StyleBoxTexture`` 9-slices so the interface uses the real artwork.
##
## GUI art lives in ``__core__/graphics/gui-new.png`` as 2x material drawn at
## ``default_sprite_scale`` 0.5, so every sheet is halved once on load and all
## positions, sizes and borders are scaled with it.

const STYLE_FILE := "res://assets/data/prototypes/gui-style.json"
const FONT_DIR_NAME := "core/fonts"

## Which TTF backs each built-in Factorio font family.
const FONT_FILES := {
	"default": "Lato-Regular.ttf",
	"default-semibold": "Lato-Semibold.ttf",
	"default-bold": "Lato-Bold.ttf",
	"default-listbox": "Lato-Regular.ttf",
	"default-dropdown": "Lato-Regular.ttf",
	"default-dialog-button": "Lato-Bold.ttf",
}
const FONT_FALLBACK := "Lato-Regular.ttf"

var styles: Dictionary = {}
var default_tileset: String = "__core__/graphics/gui-new.png"
var sprite_scale: float = 0.5

var _resolved: Dictionary = {}
var _textures: Dictionary = {}
var _texture_paths: Dictionary = {}
var _fonts: Dictionary = {}


func _ready() -> void:
	var text := FileAccess.get_file_as_string(STYLE_FILE)
	if text.is_empty():
		push_error("FactorioStyle: gui-style.json missing; run tools/factorio_extract/convert.py")
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary and parsed.has("default"):
		styles = parsed["default"]
		default_tileset = str(styles.get("default_tileset", default_tileset))
		sprite_scale = float(styles.get("default_sprite_scale", 0.5))
	print("FactorioStyle: %d styles, tileset %s" % [styles.size(), default_tileset])


# --------------------------------------------------------------------------
# style resolution
# --------------------------------------------------------------------------

## A style with its whole ``parent`` chain merged in (child wins).
func style(style_name: String) -> Dictionary:
	if _resolved.has(style_name):
		return _resolved[style_name]
	var chain: Array = []
	var cursor := style_name
	var guard := 0
	while not cursor.is_empty() and styles.has(cursor) and guard < 16:
		chain.append(styles[cursor])
		cursor = str(styles[cursor].get("parent", ""))
		guard += 1
	if chain.is_empty():
		_resolved[style_name] = {}
		return {}

	# ``chain`` runs child -> parent, so it is walked backwards: the parent's
	# values are laid down first and the child overrides them.
	var merged: Dictionary = {}
	for index in range(chain.size() - 1, -1, -1):
		var entry: Dictionary = chain[index]
		for key: String in entry:
			if key == "parent":
				continue
			merged[key] = entry[key]
	merged["name"] = style_name
	_resolved[style_name] = merged
	return merged


func has(style_name: String) -> bool:
	return styles.has(style_name)


func type_of(style_name: String) -> String:
	return str(style(style_name).get("type", ""))


# --------------------------------------------------------------------------
# colours
# --------------------------------------------------------------------------

## Factorio writes colours either as 0..1 floats or as 0..255 integers.
static func parse_color(value: Variant, fallback := Color.WHITE) -> Color:
	if value == null:
		return fallback
	if value is String:
		return Color.from_string(value, fallback)
	var r := 1.0
	var g := 1.0
	var b := 1.0
	var a := 1.0
	if value is Array and value.size() >= 3:
		r = float(value[0])
		g = float(value[1])
		b = float(value[2])
		if value.size() > 3:
			a = float(value[3])
	elif value is Dictionary:
		r = float(value.get("r", 1.0))
		g = float(value.get("g", 1.0))
		b = float(value.get("b", 1.0))
		a = float(value.get("a", 1.0))
	else:
		return fallback
	# Factorio writes some colours as 0-255 bytes and some as 0-1 floats, and
	# a three-component colour has no alpha byte at all.  Dividing the whole
	# group by 255 turned a default alpha of 1.0 into 0.004, which made every
	# such label invisible — menu buttons had no readable text at all.
	if r > 1.5:
		r /= 255.0
	if g > 1.5:
		g /= 255.0
	if b > 1.5:
		b /= 255.0
	if a > 1.5:
		a /= 255.0
	return Color(r, g, b, a)


func color(style_name: String, key: String, fallback := Color.WHITE) -> Color:
	var entry := style(style_name)
	for candidate in [key, "default_font_color", "font_color"]:
		if entry.has(candidate):
			return parse_color(entry[candidate], fallback)
	return fallback


# --------------------------------------------------------------------------
# textures
# --------------------------------------------------------------------------

## A GUI sheet, pre-scaled to display resolution.
func sheet(reference: String) -> Texture2D:
	var key := reference
	if _textures.has(key):
		return _textures[key]
	var source := FactorioAssets.image(reference)
	if source == null:
		_textures[key] = null
		return null
	var scaled := source.duplicate() as Image
	var width := maxi(1, int(round(source.get_width() * sprite_scale)))
	var height := maxi(1, int(round(source.get_height() * sprite_scale)))
	scaled.resize(width, height, Image.INTERPOLATE_LANCZOS)
	var texture := ImageTexture.create_from_image(scaled)
	_textures[key] = texture
	_texture_paths[texture] = reference
	return texture


## Size in sheet pixels of a 9-slice element.
##
## Factorio omits ``size`` for its "composition" sprites: those are a corner
## block, a one pixel stretchable middle and another corner block.
static func element_size(element: Dictionary) -> float:
	if element.has("size"):
		var size: Variant = element["size"]
		if size is Array:
			return float(size[0])
		return float(size)
	if element.has("corner_size"):
		return float(element["corner_size"]) * 2.0 + 1.0
	if element.has("border"):
		return float(element["border"]) * 2.0 + 1.0
	return 0.0


## Build the 9-slice box for one graphical-set element.
func _stylebox_from(element: Dictionary, filename: String) -> StyleBoxTexture:
	var reference := filename if not filename.is_empty() else default_tileset
	var texture := sheet(reference)
	if texture == null:
		return null

	var size := element_size(element)
	if size <= 0.0:
		return null
	var position: Variant = element.get("position", [0, 0])
	var px := float(position[0]) * sprite_scale if position is Array else 0.0
	var py := float(position[1]) * sprite_scale if position is Array else 0.0

	var box := StyleBoxTexture.new()
	box.texture = texture
	box.region_rect = Rect2(px, py, size * sprite_scale, size * sprite_scale)

	# The margin is how much of the region is a fixed corner.
	var margin_source := 0.0
	if element.has("border"):
		margin_source = float(element["border"])
	elif element.has("corner_size"):
		margin_source = float(element["corner_size"])
	var margin := margin_source * sprite_scale
	if margin > 0.0:
		box.texture_margin_left = margin
		box.texture_margin_right = margin
		box.texture_margin_top = margin
		box.texture_margin_bottom = margin

	box.modulate_color = parse_color(element.get("tint"), Color.WHITE)
	return box


## The nine-slice for a style state: ``default``, ``hovered``, ``clicked``,
## ``disabled`` or ``selected``.
func stylebox(style_name: String, state := "default") -> StyleBoxTexture:
	var entry := style(style_name)
	if entry.is_empty():
		return null
	# Different widget families name their nine-slice differently:
	# buttons and frames use *_graphical_set, text boxes use *_background.
	var candidates := [
		"%s_graphical_set" % state, "%s_background" % state,
	]
	if state == "disabled":
		candidates.append("default_graphical_set")
	if state == "clicked":
		candidates.append("hovered_graphical_set")
	candidates.append_array(["default_graphical_set", "graphical_set",
		"default_background", "background_graphical_set"])
	var gset: Variant = null
	for candidate: String in candidates:
		if entry.has(candidate) and entry[candidate] is Dictionary:
			gset = entry[candidate]
			break
	if not (gset is Dictionary):
		return null

	var filename := str(gset.get("filename", ""))
	var element: Variant = gset.get("base")
	if element == null:
		element = gset.get("background")
	if not (element is Dictionary):
		return null
	return _stylebox_from(element, filename)


# --------------------------------------------------------------------------
# metrics
# --------------------------------------------------------------------------

func number(style_name: String, key: String, fallback := 0.0) -> float:
	var entry := style(style_name)
	if not entry.has(key):
		return fallback
	return float(entry[key]) * sprite_scale if key.begins_with("corner") else float(entry[key])


func padding(style_name: String) -> Dictionary:
	var entry := style(style_name)
	var uniform: Variant = entry.get("padding")
	var out := {
		"left": float(entry.get("left_padding", uniform if uniform != null else 0.0)),
		"right": float(entry.get("right_padding", uniform if uniform != null else 0.0)),
		"top": float(entry.get("top_padding", uniform if uniform != null else 0.0)),
		"bottom": float(entry.get("bottom_padding", uniform if uniform != null else 0.0)),
	}
	return out


func size_of(style_name: String, fallback := Vector2(0, 0)) -> Vector2:
	var entry := style(style_name)
	var size := float(entry.get("size", 0.0))
	if size > 0.0:
		return Vector2(size, size)
	return Vector2(
		float(entry.get("width", fallback.x)),
		float(entry.get("height", fallback.y)))


func minimal_size(style_name: String) -> Vector2:
	var entry := style(style_name)
	var pads := padding(style_name)
	return Vector2(
		float(entry.get("minimal_width", 0.0)) + pads["left"] + pads["right"],
		float(entry.get("minimal_height", 0.0)) + pads["top"] + pads["bottom"])


# --------------------------------------------------------------------------
# fonts
# --------------------------------------------------------------------------

func font(style_or_font := "default") -> Font:
	var family := style_or_font
	var entry := style(style_or_font)
	if not entry.is_empty():
		family = str(entry.get("font", "default"))
	if _fonts.has(family):
		return _fonts[family]
	var file_name: String = FONT_FILES.get(family, FONT_FALLBACK)
	var path := FactorioAssets.data_path.path_join(FONT_DIR_NAME).path_join(file_name)
	var loaded: Font = null
	var source := FactorioAssets.packed_file(path)
	if not source.is_empty():
		var font_file := FontFile.new()
		if source.begins_with("res://") or source.begins_with("user://"):
			var bytes := FileAccess.get_file_as_bytes(source)
			if not bytes.is_empty():
				font_file.set_data(bytes)
		else:
			font_file.load_dynamic_font(source)
		if font_file.get_data().size() > 0:
			loaded = font_file
	if loaded == null:
		var fallback_path := FactorioAssets.data_path.path_join(
			FONT_DIR_NAME).path_join(FONT_FALLBACK)
		var fallback_source := FactorioAssets.packed_file(fallback_path)
		var fallback := FontFile.new()
		if fallback_source.begins_with("res://") or fallback_source.begins_with("user://"):
			fallback.set_data(FileAccess.get_file_as_bytes(fallback_source))
		elif not fallback_source.is_empty():
			fallback.load_dynamic_font(fallback_source)
		loaded = fallback
	_fonts[family] = loaded
	return loaded


func font_size(style_or_font := "default") -> int:
	var entry := style(style_or_font)
	if not entry.is_empty():
		var named := str(entry.get("font", "default"))
		var proto := Prototypes.get_p("font", named)
		if not proto.is_empty():
			return int(proto.get("size", 14))
		return 14
	var proto := Prototypes.get_p("font", style_or_font)
	if not proto.is_empty():
		return int(proto.get("size", 14))
	return 14


# --------------------------------------------------------------------------
# Godot theme
# --------------------------------------------------------------------------

## A ``Theme`` covering the controls this project uses, styled from the data.
func build_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font = font("default")
	theme.default_font_size = font_size("default")

	_theme_button(theme, "Button", "button")
	_theme_button(theme, "OptionButton", "dropdown_button")
	_theme_frame(theme, "Panel", "inside_shallow_frame_with_padding")
	_theme_frame(theme, "PanelContainer", "frame")
	_theme_frame(theme, "TooltipPanel", "tooltip_frame")
	_theme_label(theme, "Label", "label")
	_theme_label(theme, "RichTextLabel", "label")
	_theme_frame(theme, "ProgressBar", "progressbar")
	_theme_textfield(theme, "LineEdit", "textbox")
	_theme_tooltip(theme)
	return theme


func _theme_textfield(theme: Theme, control: String, style_name: String) -> void:
	theme.add_type(control)
	for state: String in ["default", "disabled"]:
		var box := stylebox(style_name, state)
		if box != null:
			theme.set_stylebox("normal" if state == "default" else "read_only", control, box)
	var focused := stylebox(style_name, "default")
	if focused != null:
		theme.set_stylebox("focus", control, focused)
	theme.set_color("font_color", control, color(style_name, "font_color", Color(0.9, 0.9, 0.9)))
	theme.set_color("font_placeholder_color", control, Color(0.6, 0.6, 0.6, 0.8))
	theme.set_color("caret_color", control, Color(0.9, 0.9, 0.9))


## Factorio's own tooltip frame, so recipe and item hovers look native.
func _theme_tooltip(theme: Theme) -> void:
	theme.add_type("TooltipPanel")
	var box := stylebox("tooltip_frame")
	if box != null:
		theme.set_stylebox("panel", "TooltipPanel", box)
	theme.add_type("TooltipLabel")
	theme.set_color("font_color", "TooltipLabel",
		color("tooltip_label", "font_color", Color(0.92, 0.92, 0.92)))
	theme.set_font("font", "TooltipLabel", font("tooltip_label"))
	theme.set_font_size("font_size", "TooltipLabel", font_size("tooltip_label"))


func _theme_button(theme: Theme, control: String, style_name: String) -> void:
	theme.add_type(control)
	for state: String in ["default", "hovered", "clicked", "disabled"]:
		var box := stylebox(style_name, state)
		if box != null:
			theme.set_stylebox(state, control, box)
	theme.set_color("font_color", control, color(style_name, "default_font_color"))
	theme.set_color("font_hover_color", control, color(style_name, "hovered_font_color"))
	theme.set_color("font_pressed_color", control, color(style_name, "clicked_font_color"))
	theme.set_color("font_disabled_color", control, color(style_name, "disabled_font_color",
		Color(0.6, 0.6, 0.6)))


func _theme_frame(theme: Theme, control: String, style_name: String) -> void:
	theme.add_type(control)
	var box := stylebox(style_name)
	if box != null:
		theme.set_stylebox("panel", control, box)


func _theme_label(theme: Theme, control: String, style_name: String) -> void:
	theme.add_type(control)
	theme.set_color("font_color", control, color(style_name, "font_color"))


## The ``__mod__/...`` reference a loaded sheet came from, for offline dumps.
func path_for(texture: Texture2D) -> String:
	return str(_texture_paths.get(texture, ""))


func stats() -> Dictionary:
	return {"styles": styles.size(), "resolved": _resolved.size(),
		"sheets": _textures.size(), "fonts": _fonts.size()}
