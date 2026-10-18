class_name TooltipLayer
extends Control
## Factorio's own tooltip: a card that follows the mouse.
##
## Godot's built-in tooltip is a plain label in a themed frame, which is not
## what the original shows — it draws a card with the name in bold, the
## description, and rows of icons with their numbers.  This is that card.
##
## Controls advertise what they want shown by setting the ``tooltip_card``
## metadata to one of the dictionaries ``Tooltips`` builds; the layer looks at
## whatever is under the mouse each frame and walks up the tree to find one.

const MAX_WIDTH := 356.0
## How far from the cursor the card sits, and how close to the edge it may get.
const OFFSET := Vector2(18, 20)
const EDGE := 6.0
## Rows are redrawn only when the card actually changes.
var _key := ""
## Set while a card is being shown for a dump, so the hover loop leaves it be.
var _pinned := false

var _frame: PanelContainer
var _body: VBoxContainer
var _title: Label
var _description: Label
var _rows: VBoxContainer
var _footer: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Above every window the game draws.
	z_index = 400

	_frame = PanelContainer.new()
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := FactorioStyle.stylebox("tooltip_frame", "default")
	if style == null:
		style = FactorioStyle.stylebox("frame", "default")
	if style != null:
		_frame.add_theme_stylebox_override("panel", style)
	_frame.custom_minimum_size = Vector2(160, 0)
	add_child(_frame)

	_body = UiKit.column(3)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(_body)

	_title = _make_label("tooltip_title_label")
	_body.add_child(_title)
	_description = _make_label("tooltip_label")
	_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_description.visible = false
	_body.add_child(_description)
	_rows = UiKit.column(2)
	_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(_rows)
	_footer = _make_label("tooltip_label")
	_footer.visible = false
	_body.add_child(_footer)

	visible = false


func _make_label(style_name: String) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := FactorioStyle.font(_style_font(style_name))
	if font != null:
		label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size",
		FactorioStyle.font_size(_style_font(style_name)))
	label.custom_minimum_size = Vector2(0, 0)
	label.set_meta("factorio_style", style_name)
	return label


## The font a tooltip style asks for, read from the style itself.
static func _style_font(style_name: String) -> String:
	var definition: Variant = FactorioStyle.styles.get(style_name)
	if definition is Dictionary and (definition as Dictionary).has("font"):
		return str((definition as Dictionary)["font"])
	return "default"


func _process(_delta: float) -> void:
	if _pinned:
		return
	var source := _hovered_card_source()
	if source == null:
		if visible:
			visible = false
			_key = ""
		return
	var card: Variant = source.get_meta("tooltip_card", null)
	if not (card is Dictionary):
		return
	var key := str((card as Dictionary).get("title", "")) + "|" \
		+ str((card as Dictionary).get("rows", []).size())
	if key != _key:
		_key = key
		_build(card)
	visible = true
	_place()


## The nearest ancestor of whatever the mouse is over that carries a card.
func _hovered_card_source() -> Control:
	var hovered := get_viewport().gui_get_hovered_control()
	# `node` has to be a plain Node.  The walk goes all the way up the tree, and
	# a Control-typed variable cannot hold the CanvasLayer, Window or Viewport
	# it meets on the way — Godot threw "Trying to assign value of type
	# CanvasLayer to a variable of type Control" every frame the mouse was over
	# anything inside a CanvasLayer, which is the whole interface and the main
	# menu on startup.
	var node: Node = hovered
	while node != null:
		if node.has_meta("tooltip_card") and node is Control:
			return node as Control
		node = node.get_parent()
	return null


func _build(card: Dictionary) -> void:
	_title.text = str(card.get("title", ""))
	var description := str(card.get("description", ""))
	_description.text = description
	_description.visible = not description.is_empty()
	for child in _rows.get_children():
		# Freed at once, not queued: the minimum size below is read this frame.
		_rows.remove_child(child)
		child.free()
	for row: Variant in card.get("rows", []):
		if not (row is Dictionary):
			continue
		_rows.add_child(_make_row(row))
	var footer := str(card.get("footer", ""))
	_footer.text = footer
	_footer.visible = not footer.is_empty()
	_frame.custom_minimum_size = Vector2(
		minf(MAX_WIDTH, maxf(160.0, _title.get_minimum_size().x + 24.0)), 0)


## One row: an icon if there is one, then the text, bold if it is a heading.
func _make_row(row: Dictionary) -> Control:
	var line := UiKit.row(4)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon: Variant = row.get("icon", null)
	if icon is Texture2D:
		var node := TextureRect.new()
		node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		node.custom_minimum_size = Vector2(22, 22)
		node.texture = icon
		node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(node)
	var label := Label.new()
	label.text = str(row.get("text", ""))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if bool(row.get("heading", false)):
		var bold := FactorioStyle.font("default-bold")
		if bold != null:
			label.add_theme_font_override("font", bold)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(label)
	return line


## Put the card next to the cursor, pulled back inside the screen if it would
## run off an edge.
func _place() -> void:
	var mouse := get_viewport().get_mouse_position()
	var viewport := get_viewport_rect().size
	var extent := _frame.get_combined_minimum_size()
	extent.x = minf(extent.x, MAX_WIDTH)
	var target := mouse + OFFSET
	target.x = minf(target.x, viewport.x - extent.x - EDGE)
	target.y = minf(target.y, viewport.y - extent.y - EDGE)
	target.x = maxf(EDGE, target.x)
	target.y = maxf(EDGE, target.y)
	_frame.position = target
	_frame.size = Vector2(extent.x, maxf(extent.y, _body.get_combined_minimum_size().y))


## Show one card at a fixed spot, for the headless UI dump where there is no
## mouse to hover with.
func preview_card(card: Dictionary, at: Vector2) -> void:
	_pinned = true
	_build(card)
	visible = true
	var extent := _frame.get_combined_minimum_size()
	_frame.position = at
	_frame.size = Vector2(minf(extent.x, MAX_WIDTH),
		maxf(extent.y, _body.get_combined_minimum_size().y))


## Give a control a card to show, and take Godot's own tooltip away so the two
## cannot both appear.
static func attach(control: Control, card: Dictionary) -> void:
	control.set_meta("tooltip_card", card)
	control.tooltip_text = ""
