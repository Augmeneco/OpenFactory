class_name Toolbar
extends Control
## The row of buttons beside the quickbar.
##
## Factorio's bar carries the blueprint tools, the ALT toggle and the undo
## stack.  Only the buttons this build can actually honour are here — ALT mode,
## the ore overlay, the chunk grid, the minimap and the research screen — and
## the rest of the row is left out rather than faked.  Each button that toggles
## something stays visibly pressed while it is on.

const BUTTON := 40
const GAP := 2

signal toggled(name: String, on: bool)
signal pressed_action(name: String)

## name -> Button, so a key press can light the matching button up.
var _buttons: Dictionary = {}
var _states: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(0, BUTTON)

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", GAP)
	add_child(row)

	_add_toggle(row, "alt", "ALT", "Show what every machine is making")
	_add_toggle(row, "ore", "ORE", "Show the ore overlay")
	_add_toggle(row, "grid", "GRID", "Show the chunk grid")
	_add_toggle(row, "map", "MAP", "Show the minimap")
	_add_toggle(row, "alerts", "!", "Show the alert column")
	_add_press(row, "research", "T", "Open the research screen")


func _add_toggle(parent: Node, name: String, label: String,
		description: String) -> void:
	var button := Button.new()
	button.text = label
	button.tooltip_text = description
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(BUTTON, BUTTON)
	button.clip_contents = true
	_style(button, false)
	button.toggled.connect(func(on: bool) -> void:
		_states[name] = on
		_style(button, on)
		toggled.emit(name, on))
	parent.add_child(button)
	_buttons[name] = button
	_states[name] = false


func _add_press(parent: Node, name: String, label: String,
		description: String) -> void:
	var button := Button.new()
	button.text = label
	button.tooltip_text = description
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(BUTTON, BUTTON)
	button.clip_contents = true
	_style(button, false)
	button.pressed.connect(func() -> void: pressed_action.emit(name))
	parent.add_child(button)
	_buttons[name] = button


func _style(button: Button, on: bool) -> void:
	for state: String in ["default", "hovered", "pressed"]:
		var style_name := "button" if state == "default" else "button"
		var box := FactorioStyle.stylebox(style_name, state)
		if box == null:
			continue
		if on and state == "default":
			# A lit toggle gets Factorio's green, the same as its own toggles.
			var tinted := box.duplicate() as StyleBox
			if tinted is StyleBoxFlat:
				(tinted as StyleBoxFlat).bg_color = Color(0.35, 0.7, 0.3, 0.9)
			box = tinted
		button.add_theme_stylebox_override(
			String({"default": "normal", "hovered": "hover",
				"pressed": "pressed"}[state]), box)


## Light or clear one of the toggles without emitting, for a key press.
func set_toggle(name: String, on: bool) -> void:
	var button: Button = _buttons.get(name)
	if button == null:
		return
	button.set_pressed_no_signal(on)
	_states[name] = on
	_style(button, on)


## The ALT toggle, named so the key handler reads clearly.
func set_alt(on: bool) -> void:
	set_toggle("alt", on)


func is_on(name: String) -> bool:
	return bool(_states.get(name, false))
