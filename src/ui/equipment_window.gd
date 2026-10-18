class_name EquipmentWindow
extends Control
## The power armour's grid, on E.
##
## The grid is drawn cell by cell at Factorio's 80-pixel cell, laid out by the
## shapes the equipment prototypes declare, so a 2x4 exoskeleton looks like a
## 2x4 hole in the layout it fills.  Clicking a piece takes it out; clicking a
## free cell with a holdable piece selected puts one in.

const CELL := 80
const GAP := 0

var player: Player

var _window: PanelContainer
var _grid: Control
var _title: Label
var _summary: Label
var _hint: Label


func _init(player_: Player) -> void:
	player = player_


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.fill_parent(self)
	visible = false
	_build()
	player.equipment_changed.connect(refresh)
	player.inventory_changed.connect(refresh)
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

	_window = UiKit.frame("Equipment", "inside_shallow_frame_with_padding")
	centre.add_child(_window)
	var body := UiKit.body(_window) as VBoxContainer
	# The frame's heading is the body's first child, not the window's.
	_title = body.get_child(0) as Label

	_summary = UiKit.label("", "label")
	body.add_child(_summary)

	# The grid itself: one Control that draws every cell and every piece.
	_grid = Control.new()
	_grid.mouse_filter = Control.MOUSE_FILTER_STOP
	_grid.gui_input.connect(_on_grid_input)
	body.add_child(_grid)

	_hint = UiKit.label("", "label")
	body.add_child(_hint)

	var row := UiKit.row(4)
	row.alignment = BoxContainer.ALIGNMENT_END
	var close := UiKit.button("Close", "button")
	close.pressed.connect(close_window)
	row.add_child(close)
	body.add_child(row)


func refresh() -> void:
	if _grid == null or player == null or player.character == null:
		return
	var grid := player.character.equipment
	_grid.custom_minimum_size = Vector2(
		maxi(1, grid.width) * (CELL + GAP), maxi(1, grid.height) * (CELL + GAP))
	_grid.queue_redraw()
	_title.text = "Equipment" if grid.armor.is_empty() \
		else Loc.proto_name("armor", grid.armor)
	if grid.armor.is_empty():
		_summary.text = "No armor worn.  Select a suit in the inventory to put it on."
	else:
		var effects := grid.effects()
		_summary.text = "%dx%d grid, %d fitted   |   shield %.0f/%.0f   speed +%.0f%%" % [
			grid.width, grid.height, grid.items.size(), grid.shield,
			grid.max_shield, float(effects["movement_bonus"]) * 100.0]
	var held := player.selected_item()
	if not held.is_empty() and not Prototypes.equipment_proto(held).is_empty():
		_hint.text = "Click a free cell to fit %s." % Loc.proto_name("item", held)
	elif not held.is_empty() and not Prototypes.get_p("armor", held).is_empty():
		_hint.text = "This suit is worn from the inventory, not fitted here."
	else:
		_hint.text = "Click a fitted piece to take it out."


## The grid as data, because a picture of a _draw call cannot be taken from a
## control list and the headless previewer has no way to see it.
func overlay_lines() -> Array:
	var out: Array = []
	if not visible or player == null or player.character == null:
		return out
	var grid := player.character.equipment
	if grid.width <= 0:
		return out
	var origin := _grid.global_position
	for y in grid.height:
		for x in grid.width:
			out.append(_box(origin + Vector2(x, y) * CELL, Vector2(CELL, CELL),
				[0.3, 0.32, 0.35, 1.0], 1.0))
	for item: Dictionary in grid.items:
		var size := EquipmentVector(EquipmentGrid.shape_of(str(item["name"])))
		out.append(_box(origin + Vector2(int(item["x"]), int(item["y"])) * CELL,
			size * CELL, [0.6, 0.85, 0.6, 1.0], 2.0))
	return out


static func EquipmentVector(size: Vector2i) -> Vector2:
	return Vector2(size)


## A closed rectangle as the four lines the previewer understands.
static func _box(at: Vector2, size: Vector2, colour: Array,
		width: float) -> Dictionary:
	var corners := [at, at + Vector2(size.x, 0), at + size,
		at + Vector2(0, size.y), at]
	var points: Array = []
	for corner: Vector2 in corners:
		points.append([corner.x, corner.y])
	return {"points": points, "color": colour, "width": width}


## Cells are drawn from the prototypes, so the picture always matches the model.
func _draw() -> void:
	if player == null or player.character == null:
		return
	var grid := player.character.equipment
	if grid.width <= 0:
		return
	# The empty grid: one square per cell.
	for y in grid.height:
		for x in grid.width:
			var cell := Rect2(Vector2(x, y) * CELL, Vector2(CELL - GAP, CELL - GAP))
			draw_rect(cell, Color(0.16, 0.17, 0.19, 0.9), true)
			draw_rect(cell, Color(0.3, 0.32, 0.35, 1.0), false, 1.0)
	# Then every fitted piece, over the cells it covers.
	for item: Dictionary in grid.items:
		var name := str(item["name"])
		var size := EquipmentGrid.shape_of(name)
		var origin := Vector2(int(item["x"]), int(item["y"])) * CELL
		var rect := Rect2(origin, Vector2(size) * CELL - Vector2(GAP, GAP))
		var selected := str(item["name"]) == player.selected_item()
		draw_rect(rect, Color(0.24, 0.3, 0.26, 0.95) if not selected
			else Color(0.3, 0.42, 0.32, 0.95), true)
		draw_rect(rect, Color(0.5, 0.75, 0.5, 1.0) if not selected
			else Color(0.75, 0.95, 0.6, 1.0), false, 2.0)
		var icon := FactorioAssets.prototype_icon(
			Prototypes.item_proto(name), 64)
		if icon != null:
			var pad := rect.size * 0.1
			draw_texture_rect(icon, Rect2(rect.position + pad,
				rect.size - pad * 2.0), false, Color(1, 1, 1, 0.95))


func _on_grid_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return
	var cell := Vector2i(floor(button.position.x / CELL),
		floor(button.position.y / CELL))
	var grid := player.character.equipment
	var fitted := grid.at_cell(cell)
	if not fitted.is_empty():
		player.remove_equipment_at(Vector2i(int(fitted["x"]), int(fitted["y"])))
		return
	var held := player.selected_item()
	if held.is_empty() or Prototypes.equipment_proto(held).is_empty():
		return
	player.fit_equipment(held, cell)


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
