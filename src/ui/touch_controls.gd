class_name TouchControls
extends Control
## Compact touch HUD for Android/tablet play.
##
## Left joystick moves the engineer.  The mouse buttons above it click at the
## virtual pointer; the right joystick moves that pointer, so the player can
## interact with the world without covering it with a finger.  Only five action
## buttons sit permanently on screen; everything else is behind MORE.

signal action(name: String)
signal move_changed(direction: Vector2)
signal pointer_changed(position: Vector2)

const BUTTON := 76.0
const GAP := 10.0
const LEFT_MARGIN := 32.0
## Keep the right-hand controls away from curved display corners.
const SAFE := 56.0
const JOYSTICK := 232.0
const AIM_JOYSTICK := 188.0
const MOUSE_W := 88.0
const MOUSE_H := 64.0
const POINTER_SPEED := 430.0

var _joystick: TouchJoystick
var _aim_joystick: TouchJoystick
var _buttons: Dictionary = {}
var _more: PanelContainer
var _more_open := false
var _pointer := Vector2.ZERO
var _pointer_ready := false
var _pointer_visible := false
var _move_label: Label
var _aim_label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = FactorioStyle.build_theme()

	_joystick = TouchJoystick.new()
	_joystick.name = "TouchJoystick"
	_joystick.moved.connect(func(direction: Vector2) -> void:
		move_changed.emit(direction))
	add_child(_joystick)

	_aim_joystick = TouchJoystick.new()
	_aim_joystick.name = "TouchAimJoystick"
	_aim_joystick.moved.connect(_on_aim_moved)
	add_child(_aim_joystick)
	_move_label = _make_joystick_label("MOVE")
	_aim_label = _make_joystick_label("AIM")

	_add_direct("rot", "ROT", "rotate")
	_add_direct("fire", "FIRE", "fire", true)
	_add_direct("inv", "INV", "inventory")
	_add_direct("tech", "TECH", "research")
	_add_direct("more", "MORE", "more")
	_add_mouse_button("lmb", "LMB", "mouse_left", false)
	_add_mouse_button("rmb", "RMB", "mouse_right", true)
	_build_more()
	_pointer = get_viewport_rect().size * 0.5
	_pointer_ready = true
	layout(get_viewport_rect().size)
	get_viewport().size_changed.connect(_on_resized)


func _make_joystick_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", FactorioStyle.font("default"))
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.88, 0.83, 0.66, 0.9))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 3)
	add_child(label)
	return label


func _add_direct(key: String, label: String, action_name: String,
		accent := false) -> void:
	var button := _make_button(label, BUTTON, accent)
	button.name = "Touch" + key.capitalize()
	button.pressed.connect(_on_direct.bind(key, action_name))
	add_child(button)
	_buttons[key] = button


func _add_mouse_button(key: String, label: String, action_name: String,
		accent: bool) -> void:
	var button := _make_button(label, MOUSE_H, accent)
	button.name = "Touch" + key.capitalize()
	button.custom_minimum_size = Vector2(MOUSE_W, MOUSE_H)
	button.size = Vector2(MOUSE_W, MOUSE_H)
	button.add_theme_font_size_override("font_size", 17)
	if key == "rmb":
		button.button_down.connect(func() -> void:
			_pointer_visible = true
			queue_redraw()
			action.emit("mouse_right_down"))
		button.button_up.connect(func() -> void:
			action.emit("mouse_right_up"))
	else:
		button.button_down.connect(func() -> void:
			_pointer_visible = true
			queue_redraw()
			action.emit(action_name))
	add_child(button)
	_buttons[key] = button


func _on_direct(key: String, action_name: String) -> void:
	if key == "more":
		_more_open = not _more_open
		_more.visible = _more_open
		_buttons["more"].modulate = Color(1.0, 0.88, 0.55) if _more_open \
			else Color.WHITE
		return
	action.emit(action_name)


func _on_aim_moved(direction: Vector2) -> void:
	if direction.length_squared() > 0.001 and not _pointer_visible:
		_pointer_visible = true
		queue_redraw()
	if _pointer_visible:
		queue_redraw()


func _build_more() -> void:
	_more = PanelContainer.new()
	_more.name = "TouchMore"
	_more.visible = false
	_more.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.05, 0.055, 0.96)
	style.border_color = Color(0.72, 0.58, 0.28, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(5)
	style.set_content_margin_all(8)
	_more.add_theme_stylebox_override("panel", style)
	add_child(_more)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	_more.add_child(column)
	var title := Label.new()
	title.text = "MORE  •  tap = build, double tap = open, hold = mine"
	title.add_theme_font_override("font", FactorioStyle.font("default"))
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(0.78, 0.76, 0.68))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size = Vector2(332, 0)
	column.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	column.add_child(grid)
	var entries := [
		["MAP", "map"], ["EQUIP", "equipment"], ["PROD", "production"],
		["VEH", "vehicle"], ["PICK", "pick"], ["REMOVE", "remove"],
		["WIRE", "wire"], ["ALT", "alt"], ["ORE", "ore"], ["GRID", "grid"],
		["ALERTS", "alerts"], ["HOME", "home"], ["SAVE", "save"],
		["LOAD", "load"], ["PAUSE", "pause"], ["+", "zoom_in"],
		["−", "zoom_out"],
	]
	for entry: Array in entries:
		var button := _make_button(str(entry[0]), 58.0)
		button.custom_minimum_size = Vector2(86, 58)
		button.size = Vector2(86, 58)
		button.pressed.connect(_on_more_action.bind(str(entry[1])))
		grid.add_child(button)
	_more.custom_minimum_size = Vector2(382, 372)


func _on_more_action(action_name: String) -> void:
	_on_direct("more", "more")
	action.emit(action_name)


func _make_button(label: String, side: float, accent := false) -> Button:
	var button := Button.new()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.custom_minimum_size = Vector2(side, side)
	button.size = Vector2(side, side)
	button.add_theme_font_override("font", FactorioStyle.font("default"))
	button.add_theme_font_size_override("font_size", 15 if label.length() > 3 else 19)
	button.add_theme_color_override("font_color", Color(0.93, 0.91, 0.84))
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	var base := Color(0.72, 0.50, 0.22) if accent else Color(0.62, 0.48, 0.25)
	for state: String in ["normal", "hover", "pressed", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.055, 0.06, 0.065, 0.94)
		if state == "pressed":
			box.bg_color = Color(0.34, 0.27, 0.12, 0.98)
		elif state == "hover":
			box.bg_color = Color(0.12, 0.11, 0.08, 0.98)
		if state == "focus":
			box.bg_color = Color.TRANSPARENT
			box.border_color = Color.TRANSPARENT
		box.border_color = base
		box.set_border_width_all(2 if state != "focus" else 0)
		box.set_corner_radius_all(10)
		button.add_theme_stylebox_override(state, box)
	return button


func _process(delta: float) -> void:
	if not _pointer_visible or not is_visible_in_tree():
		return
	if _aim_joystick == null:
		return
	var direction := _aim_joystick.direction()
	if direction.length_squared() <= 0.0001:
		return
	_pointer += direction * POINTER_SPEED * delta
	_pointer.x = clampf(_pointer.x, 4.0, size.x - 4.0)
	_pointer.y = clampf(_pointer.y, 4.0, size.y - 4.0)
	pointer_changed.emit(_pointer)
	queue_redraw()


func _draw() -> void:
	if not _pointer_visible:
		return
	draw_circle(_pointer, 13.0, Color(0.02, 0.02, 0.02, 0.45))
	draw_arc(_pointer, 13.0, 0.0, TAU, 28, Color(1.0, 0.88, 0.45, 0.95), 2.0)
	draw_line(_pointer + Vector2(-18, 0), _pointer + Vector2(-5, 0),
		Color(1.0, 0.88, 0.45, 0.95), 2.0)
	draw_line(_pointer + Vector2(5, 0), _pointer + Vector2(18, 0),
		Color(1.0, 0.88, 0.45, 0.95), 2.0)
	draw_line(_pointer + Vector2(0, -18), _pointer + Vector2(0, -5),
		Color(1.0, 0.88, 0.45, 0.95), 2.0)
	draw_line(_pointer + Vector2(0, 5), _pointer + Vector2(0, 18),
		Color(1.0, 0.88, 0.45, 0.95), 2.0)


func layout(viewport_size: Vector2) -> void:
	if _joystick == null:
		return
	_joystick.position = Vector2(LEFT_MARGIN,
		viewport_size.y - JOYSTICK - LEFT_MARGIN)
	_joystick.size = Vector2(JOYSTICK, JOYSTICK)
	_move_label.position = Vector2(_joystick.position.x,
		_joystick.position.y + JOYSTICK - 24.0)
	_move_label.size = Vector2(JOYSTICK, 18)

	var mouse_y := _joystick.position.y - MOUSE_H - GAP
	_buttons["lmb"].position = Vector2(LEFT_MARGIN, mouse_y)
	_buttons["rmb"].position = Vector2(LEFT_MARGIN + MOUSE_W + GAP, mouse_y)

	var right := viewport_size.x - SAFE
	var bottom := viewport_size.y - SAFE
	var bottom_y := bottom - BUTTON
	var top_y := bottom_y - BUTTON - GAP
	_buttons["rot"].position = Vector2(right - 3.0 * BUTTON - 2.0 * GAP,
		bottom_y)
	_buttons["fire"].position = Vector2(right - 2.0 * BUTTON - GAP, bottom_y)
	_buttons["more"].position = Vector2(right - BUTTON, bottom_y)
	_buttons["inv"].position = Vector2(right - 2.0 * BUTTON - GAP, top_y)
	_buttons["tech"].position = Vector2(right - BUTTON, top_y)

	_aim_joystick.size = Vector2(AIM_JOYSTICK, AIM_JOYSTICK)
	_aim_joystick.position = Vector2(right - AIM_JOYSTICK,
		top_y - AIM_JOYSTICK - GAP)
	_aim_label.position = Vector2(_aim_joystick.position.x,
		_aim_joystick.position.y + AIM_JOYSTICK - 24.0)
	_aim_label.size = Vector2(AIM_JOYSTICK, 18)

	_more.size = Vector2(382, 372)
	_more.position = Vector2(right - _more.size.x,
		_aim_joystick.position.y - _more.size.y - GAP)

	if not _pointer_ready:
		_pointer = viewport_size * 0.5
		_pointer_ready = true
	else:
		_pointer = Vector2(
			clampf(_pointer.x, 4.0, viewport_size.x - 4.0),
			clampf(_pointer.y, 4.0, viewport_size.y - 4.0))
	pointer_changed.emit(_pointer)
	queue_redraw()


func _on_resized() -> void:
	layout(get_viewport_rect().size)


func pointer_position() -> Vector2:
	return _pointer


## True when a screen point belongs to the touch HUD; the world gesture then
## must not treat the same touch as a build/mine tap.
func is_menu_open() -> bool:
	return _more_open


func is_point_over_ui(point: Vector2) -> bool:
	if not visible:
		return false
	for control: Control in [_joystick, _aim_joystick, _more]:
		if control != null and control.visible \
				and control.get_global_rect().has_point(point):
			return true
	for button: Variant in _buttons.values():
		if button is Control and (button as Control).get_global_rect().has_point(point):
			return true
	return false


func reset() -> void:
	if _joystick != null:
		_joystick.reset()
	if _aim_joystick != null:
		_aim_joystick.reset()
	_pointer_visible = false
	queue_redraw()
	if _more != null:
		_more.visible = false
		_more_open = false
		if _buttons.has("more"):
			(_buttons["more"] as Button).modulate = Color.WHITE
