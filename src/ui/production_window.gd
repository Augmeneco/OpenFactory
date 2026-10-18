class_name ProductionWindow
extends Control
## The production statistics screen, on P.
##
## Factorio's window has a search box, a legend and a graph; this keeps the part
## that answers the question you open it with — what is being made, what is
## being eaten, and at what rate — as a table of the last minute's rates.

const ROW_HEIGHT := 28
const ICON := 24
## The graph's own size, and the colours of its two lines.
const GRAPH_WIDTH := 620
const GRAPH_HEIGHT := 170
const PRODUCED_COLOUR := Color(0.45, 0.85, 0.45)
const CONSUMED_COLOUR := Color(0.95, 0.55, 0.4)

var simulation: Simulation

var _window: PanelContainer
var _rows: VBoxContainer
var _search: LineEdit
var _summary: Label
var _filter := ""
var _scroll: ScrollContainer
## What the graph is showing.
var _selected := ""
var _range := "1m"
var _graph: Control
var _graph_title: Label
var _range_buttons: Dictionary = {}


func _init(simulation_: Simulation) -> void:
	simulation = simulation_


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.fill_parent(self)
	visible = false
	_build()
	refresh()


func _build() -> void:
	var wash := ColorRect.new()
	wash.color = Color(0, 0, 0, 0.35)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wash)
	UiKit.fill_parent(wash)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	UiKit.fill_parent(centre)

	_window = UiKit.frame("Production statistics", "inside_shallow_frame_with_padding")
	centre.add_child(_window)
	var body := UiKit.body(_window) as VBoxContainer

	var head := UiKit.row(6)
	_search = LineEdit.new()
	_search.placeholder_text = "Search"
	_search.custom_minimum_size = Vector2(220, 0)
	_search.text_changed.connect(func(text: String) -> void:
		_filter = text.strip_edges().to_lower()
		refresh())
	head.add_child(_search)
	_summary = UiKit.label("", "label")
	head.add_child(_summary)
	var close := UiKit.button("Close", "button")
	close.pressed.connect(close_window)
	head.add_child(close)
	body.add_child(head)

	var header := UiKit.row(6)
	header.add_child(_column_label("Item", 240))
	header.add_child(_column_label("Produced / min", 130))
	header.add_child(_column_label("Consumed / min", 130))
	header.add_child(_column_label("Net", 90))
	body.add_child(header)
	body.add_child(UiKit.hseparator())

	# The graph: one item at a time, over a range the buttons pick.
	var ranges := UiKit.row(4)
	_graph_title = UiKit.label("", "frame_subheading_label")
	ranges.add_child(_graph_title)
	for range: Dictionary in Statistics.RANGES:
		var key := str(range["key"])
		var button := UiKit.button(key, "button")
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(func() -> void: _set_range(key))
		ranges.add_child(button)
		_range_buttons[key] = button
	body.add_child(ranges)

	_graph = Control.new()
	_graph.custom_minimum_size = Vector2(GRAPH_WIDTH, GRAPH_HEIGHT)
	_graph.draw.connect(_draw_graph)
	body.add_child(_graph)

	_scroll = UiKit.scroll()
	_scroll.custom_minimum_size = Vector2(640, 420)
	body.add_child(_scroll)
	_rows = UiKit.column(2)
	_rows.custom_minimum_size = Vector2(620, 0)
	_scroll.add_child(_rows)


func _column_label(text: String, width: int) -> Label:
	var label := UiKit.label(text, "frame_subheading_label")
	label.custom_minimum_size = Vector2(width, 0)
	return label


func refresh() -> void:
	if _rows == null or simulation == null or simulation.statistics == null:
		return
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.free()
	# Open on the busiest thing there is, so the graph is never empty for no
	# reason.
	if _selected.is_empty():
		_selected = simulation.statistics.busiest(_range)
	_graph_title.text = "Graph: %s" % (Loc.proto_name("item", _selected)
		if not _selected.is_empty() else "nothing yet")
	for key: String in _range_buttons:
		(_range_buttons[key] as Button).set_pressed_no_signal(key == _range)
	_graph.queue_redraw()
	var rows := simulation.statistics.rows()
	var shown := 0
	for row: Variant in rows:
		var entry: Dictionary = row
		var name := str(entry["name"])
		if not _filter.is_empty() and not name.to_lower().contains(_filter) \
				and not Loc.proto_name("item", name).to_lower().contains(_filter):
			continue
		_rows.add_child(_make_row(entry))
		shown += 1
	if shown == 0:
		_rows.add_child(UiKit.label(
			"Nothing has been produced or consumed yet." if rows.is_empty()
			else "Nothing matches that search.", "label"))
	var totals := simulation.statistics.totals()
	_summary.text = "%d shown   |   %d items made, %d used, %d kinds" % [
		shown, int(totals["items_produced"]), int(totals["items_consumed"]),
		int(totals["kinds"])]


func _make_row(entry: Dictionary) -> Control:
	var name := str(entry["name"])
	var line := Button.new()
	line.flat = true
	line.focus_mode = Control.FOCUS_NONE
	line.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	line.pressed.connect(func() -> void:
		_selected = name
		refresh())
	var row_box := UiKit.row(6)
	row_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	row_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(row_box)
	line = line
	var _unused := line
	var line_row := row_box

	var slot := UiKit.row(4)
	slot.custom_minimum_size = Vector2(240, 0)
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = Vector2(ICON, ICON)
	icon.texture = FactorioAssets.prototype_icon(
		Prototypes.item_proto(name), 64)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	slot.add_child(icon)
	var label := UiKit.label(Loc.proto_name("item", name), "label")
	slot.add_child(label)
	line_row.add_child(slot)

	line_row.add_child(_number(float(entry["produced"]), 130,
		Color(0.6, 0.9, 0.6)))
	line_row.add_child(_number(float(entry["consumed"]), 130,
		Color(0.95, 0.75, 0.55)))
	var net := float(entry["net"])
	line_row.add_child(_number(net, 90,
		Color(0.6, 0.9, 0.6) if net >= 0.0 else Color(1.0, 0.55, 0.5)))
	return line


func _set_range(key: String) -> void:
	_range = key
	refresh()


## Two lines over the selected range: what was made, and what was eaten.
func _draw_graph() -> void:
	if simulation == null or _graph == null:
		return
	var size := Vector2(GRAPH_WIDTH, GRAPH_HEIGHT)
	_graph.draw_rect(Rect2(Vector2.ZERO, size), Color(0.12, 0.13, 0.15, 0.95),
		true)
	_graph.draw_rect(Rect2(Vector2.ZERO, size), Color(0.3, 0.32, 0.35), false, 1.0)
	if _selected.is_empty():
		return
	var produced := simulation.statistics.produced_series(_selected, _range)
	var consumed := simulation.statistics.consumed_series(_selected, _range)
	var peak := 1.0
	for value: Variant in produced + consumed:
		peak = maxf(peak, float(value))
	# A grid, so the shape has a scale to read against.
	for step in 4:
		var y := size.y * float(step) / 4.0
		_graph.draw_line(Vector2(0, y), Vector2(size.x, y),
			Color(0.25, 0.27, 0.3, 0.8), 1.0)
	_graph.draw_line(Vector2(size.x - 1, 0), Vector2(size.x - 1, size.y),
		Color(0.25, 0.27, 0.3, 0.8), 1.0)
	_plot(produced, peak, PRODUCED_COLOUR)
	_plot(consumed, peak, CONSUMED_COLOUR)


func _plot(values: Array, peak: float, colour: Color) -> void:
	if values.size() < 2:
		return
	var size := Vector2(GRAPH_WIDTH, GRAPH_HEIGHT)
	var points := PackedVector2Array()
	for index in values.size():
		var x := size.x * float(index) / float(values.size() - 1)
		var y := size.y - (float(values[index]) / peak) * (size.y - 8.0)
		points.append(Vector2(x, y))
	_graph.draw_polyline(points, colour, 2.0, true)


## The graph as data, so the headless previewer can draw it.
func overlay_lines() -> Array:
	var out: Array = []
	if not visible or _graph == null or simulation == null:
		return out
	var size := Vector2(GRAPH_WIDTH, GRAPH_HEIGHT)
	var origin := _graph.global_position
	out.append({"points": [[origin.x, origin.y], [origin.x + size.x, origin.y],
		[origin.x + size.x, origin.y + size.y], [origin.x, origin.y + size.y],
		[origin.x, origin.y]], "color": [0.3, 0.32, 0.35, 1.0], "width": 1.0})
	if _selected.is_empty():
		return out
	var produced := simulation.statistics.produced_series(_selected, _range)
	var consumed := simulation.statistics.consumed_series(_selected, _range)
	var peak := 1.0
	for value: Variant in produced + consumed:
		peak = maxf(peak, float(value))
	out.append_array(_overlay_plot(produced, peak, origin,
		[0.45, 0.85, 0.45, 1.0]))
	out.append_array(_overlay_plot(consumed, peak, origin,
		[0.95, 0.55, 0.4, 1.0]))
	return out


func _overlay_plot(values: Array, peak: float, origin: Vector2,
		colour: Array) -> Array:
	if values.size() < 2:
		return []
	var points: Array = []
	for index in values.size():
		var x := float(GRAPH_WIDTH) * float(index) / float(values.size() - 1)
		var y := float(GRAPH_HEIGHT) \
			- (float(values[index]) / peak) * (float(GRAPH_HEIGHT) - 8.0)
		points.append([origin.x + x, origin.y + y])
	return [{"points": points, "color": colour, "width": 2.0}]


func _number(value: float, width: int, colour: Color) -> Label:
	var label := UiKit.label("%.1f" % value, "label")
	label.custom_minimum_size = Vector2(width, 0)
	label.add_theme_color_override("font_color", colour)
	return label


func open_window() -> void:
	visible = true
	refresh()


func close_window() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close_window()
	else:
		open_window()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close_window()
			accept_event()
