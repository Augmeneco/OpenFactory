class_name AlertPanel
extends Control
## The column of alert icons Factorio keeps down the right-hand edge.
##
## One row per kind of problem, worst first, each with the real ``__core__``
## icon and a count.  Clicking a row takes the camera to the first machine
## complaining about it, which is what makes the panel useful rather than
## decorative.

const ROW := 44
const ICON := 32

signal alert_clicked(cell: Vector2i)

var alerts: Alerts
var camera: GameCamera

var _frame: PanelContainer
var _rows: VBoxContainer
var _rows_by_kind: Dictionary = {}
var _title: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(56, 0)

	_frame = PanelContainer.new()
	var style := FactorioStyle.stylebox("inside_shallow_frame", "default")
	if style == null:
		style = FactorioStyle.stylebox("frame", "default")
	if style != null:
		_frame.add_theme_stylebox_override("panel", style)
	add_child(_frame)

	var body := UiKit.column(4)
	_frame.add_child(body)
	_title = UiKit.label("", "label")
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.visible = false
	body.add_child(_title)

	_rows = UiKit.column(3)
	body.add_child(_rows)
	visible = false


## Redraw from the current alert list.
func refresh() -> void:
	if alerts == null or _rows == null:
		return
	var grouped := alerts.grouped()
	visible = not grouped.is_empty()
	if grouped.is_empty():
		for child in _rows.get_children():
			child.queue_free()
		_rows_by_kind.clear()
		return

	# Rebuild only when the set of kinds changed; counts are cheap to update.
	var kinds: Array = []
	for entry: Dictionary in grouped:
		kinds.append(str(entry["kind"]))
	var same := kinds.size() == _rows_by_kind.size()
	if same:
		for kind: String in kinds:
			if not _rows_by_kind.has(kind):
				same = false
				break
	if not same:
		for child in _rows.get_children():
			child.queue_free()
		_rows_by_kind.clear()
		for entry: Dictionary in grouped:
			var kind := str(entry["kind"])
			var button := _make_row(kind)
			_rows.add_child(button)
			_rows_by_kind[kind] = button

	for entry: Dictionary in grouped:
		var kind := str(entry["kind"])
		var button: Button = _rows_by_kind.get(kind)
		if button == null:
			continue
		button.set_meta("first_cell", entry["first_cell"])
		button.tooltip_text = "%s (%d)\n%s\nClick to go there" % [
			str(Alerts.TITLES.get(kind, kind)), int(entry["count"]),
			str(entry["first_message"])]
		var count: Label = button.get_node("Count")
		count.text = str(int(entry["count"])) if int(entry["count"]) > 1 else ""

	_title.text = "%d" % alerts.total()
	_title.visible = alerts.total() > 0


func _make_row(kind: String) -> Button:
	var button := Button.new()
	button.custom_minimum_size = Vector2(ROW, ROW)
	button.set_meta("kind", kind)
	var normal := FactorioStyle.stylebox("slot", "default")
	if normal != null:
		button.add_theme_stylebox_override("normal", normal)
	var hover := FactorioStyle.stylebox("slot", "hovered")
	if hover != null:
		button.add_theme_stylebox_override("hover", hover)

	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = FactorioAssets.texture(str(Alerts.ICONS.get(kind, "")))
	icon.set_meta("factorio_icon", "alert-%s" % kind)
	# The alert icons are 64 px; EXPAND_IGNORE_SIZE stops them from forcing the
	# row open, so the 32 px box is what is actually drawn.
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = Vector2(ICON, ICON)
	icon.size = Vector2(ICON, ICON)
	icon.position = Vector2((ROW - ICON) / 2, (ROW - ICON) / 2)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(icon)

	var count := Label.new()
	count.name = "Count"
	count.position = Vector2(2, ROW - 18)
	count.add_theme_color_override("font_color", Color(1, 0.85, 0.85))
	count.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	count.add_theme_constant_override("outline_size", 3)
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(count)

	button.pressed.connect(func() -> void:
		var cell: Variant = button.get_meta("first_cell", null)
		if cell is Vector2i:
			alert_clicked.emit(cell))
	return button
