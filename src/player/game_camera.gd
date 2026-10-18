class_name GameCamera
extends Camera2D
## Factorio-style viewport control: drag with the middle or right mouse
## button, zoom with the wheel, and keep the view inside sane limits.

const MIN_ZOOM := 0.20
const MAX_ZOOM := 3.0
const ZOOM_STEP := 1.12

## Zoom level 1.0 shows one tile as 32 screen pixels.
var zoom_level := 1.0

## When set, the camera tracks this world position and dragging is disabled.
var follow_target := Vector2.INF
var _dragging := false
var _drag_anchor := Vector2.ZERO
var _drag_origin := Vector2.ZERO

signal zoom_changed(level: float)


func _ready() -> void:
	zoom = Vector2.ONE * zoom_level
	position = Vector2.ZERO
	# The world is drawn in pixels, so the camera needs no extra scaling.


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					_zoom_by(ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					_zoom_by(1.0 / ZOOM_STEP)
			MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_dragging = button.pressed and not follow_target.is_finite()
				if _dragging:
					_drag_anchor = button.position
					_drag_origin = position
	elif event is InputEventMouseMotion and _dragging and not follow_target.is_finite():
		var motion := event as InputEventMouseMotion
		position = _drag_origin - (motion.position - _drag_anchor) / zoom


func _zoom_by(factor: float) -> void:
	set_zoom_level(zoom_level * factor)


## Zoom keeping the point under the mouse cursor fixed, like Factorio does.
func set_zoom_level(level: float, anchor_screen := Vector2.INF) -> void:
	var clamped := clampf(level, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(clamped, zoom_level):
		return
	var before := screen_to_world(anchor_screen)
	zoom_level = clamped
	zoom = Vector2.ONE * zoom_level
	if anchor_screen.is_finite():
		var after := screen_to_world(anchor_screen)
		position += before - after
	zoom_changed.emit(zoom_level)


## The slice of the world the camera is showing, in world pixels.
##
## Headless runs have a square viewport, so this is also what the minimap
## marks out — the rectangle follows the real viewport, not a guess.
func view_rect_world() -> Rect2:
	var viewport := get_viewport()
	var extent := Vector2(1600, 900)
	if viewport != null:
		extent = viewport.get_visible_rect().size
	var half := extent * 0.5 / maxf(0.01, zoom_level)
	return Rect2(position - half, half * 2.0)


func screen_to_world(screen: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * screen


func world_to_screen(world_pos: Vector2) -> Vector2:
	return get_canvas_transform() * world_pos


func mouse_world_position() -> Vector2:
	return screen_to_world(get_viewport().get_mouse_position())
