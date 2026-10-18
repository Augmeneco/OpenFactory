class_name PauseMenu
extends Control
## The in-game menu, on Escape.
##
## Factorio's version: Continue in green, then the save and load pair, then the
## way out.  The simulation is frozen while it is open.

signal resume_requested
signal save_requested
signal load_requested
signal settings_requested
signal quit_requested

const BUTTON_WIDTH := 300
const BUTTON_HEIGHT := 40

var _status: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.fill_parent(self)

	var wash := ColorRect.new()
	wash.color = Color(0.05, 0.05, 0.06, 0.45)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wash)
	UiKit.fill_parent(wash)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	UiKit.fill_parent(centre)

	var frame := UiKit.frame("Menu", "frame")
	centre.add_child(frame)
	var body := UiKit.body(frame) as VBoxContainer

	var buttons := UiKit.column(4)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_child(buttons)

	_add(buttons, "Continue", "menu_button_continue",
		func() -> void: resume_requested.emit())
	_add(buttons, "Save game", "menu_button",
		func() -> void: save_requested.emit())
	_add(buttons, "Load game", "menu_button",
		func() -> void: load_requested.emit())
	_add(buttons, "Settings", "menu_button",
		func() -> void: settings_requested.emit())

	body.add_child(UiKit.spacer(6.0))
	_status = UiKit.label("", "label")
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_status)

	body.add_child(UiKit.spacer(6.0))
	_add(buttons, "Quit to menu", "red_button",
		func() -> void: quit_requested.emit())

	visible = false


func _add(parent: Node, label: String, style_name: String,
		action: Callable) -> Button:
	var button := UiKit.button(label, style_name)
	button.custom_minimum_size = Vector2(BUTTON_WIDTH, BUTTON_HEIGHT)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func open_menu() -> void:
	visible = true
	_status.text = ""


func close_menu() -> void:
	visible = false


func say(message: String) -> void:
	if _status != null:
		_status.text = message
