class_name TouchJoystick
extends Control
## One-thumb movement stick for touch/mobile builds.
##
## It accepts both real screen touches and emulated mouse events, because
## Godot's Android backend normally converts a touch into a left mouse event
## for Control nodes.  The emitted vector is already normalised to [-1, 1].

signal moved(direction: Vector2)

const KNOB_RADIUS := 30.0

var _active := false
var _active_id := -1
var _mouse_active := false
var _direction := Vector2.ZERO


func _ready() -> void:
	custom_minimum_size = Vector2(188, 188)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


func _draw() -> void:
	var centre := size * 0.5
	var radius := minf(size.x, size.y) * 0.42
	draw_circle(centre, radius, Color(0.02, 0.03, 0.04, 0.62))
	draw_arc(centre, radius, 0.0, TAU, 48,
		Color(0.78, 0.64, 0.28, 0.8), 3.0, true)
	draw_arc(centre, radius * 0.56, 0.0, TAU, 40,
		Color(0.78, 0.64, 0.28, 0.25), 1.0, true)
	var knob := centre + _direction * radius * 0.55
	draw_circle(knob, KNOB_RADIUS, Color(0.72, 0.57, 0.24, 0.9))
	draw_arc(knob, KNOB_RADIUS, 0.0, TAU, 32,
		Color(1.0, 0.9, 0.58, 1.0), 2.0, true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			if not _active:
				_active = true
				_active_id = touch.index
				_set_from_screen(touch.position)
		elif _active and touch.index == _active_id:
			_release()
		accept_event()
		return
	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if _active and drag.index == _active_id:
			_set_from_screen(drag.position)
			accept_event()
		return
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.button_index != MOUSE_BUTTON_LEFT:
			return
		if mouse.pressed:
			_mouse_active = true
			_active = true
			_set_from_screen(mouse.position)
		elif _mouse_active:
			_release()
		accept_event()
	elif event is InputEventMouseMotion and _mouse_active:
		_set_from_screen((event as InputEventMouseMotion).position)
		accept_event()


func direction() -> Vector2:
	return _direction


func _set_from_screen(point: Vector2) -> void:
	var centre := size * 0.5
	var radius := maxf(1.0, minf(size.x, size.y) * 0.42)
	var delta := point - centre
	if delta.length() > radius:
		delta = delta.normalized() * radius
	_direction = delta / radius
	queue_redraw()
	moved.emit(_direction)


func _release() -> void:
	_active = false
	_active_id = -1
	_mouse_active = false
	_direction = Vector2.ZERO
	queue_redraw()
	moved.emit(Vector2.ZERO)


func reset() -> void:
	_release()
