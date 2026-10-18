class_name SaveLoadDialog
extends Control
## Named save browser.  One dialog serves both "Save game" (name + existing
## saves) and "Load game" (pick one of the named saves), so the pause menu and
## the title screen share the same files and layout.

signal save_requested(name: String)
signal load_requested(path: String)
signal cancelled

var _mode := "load"
var _title: Label
var _name_row: HBoxContainer
var _name_edit: LineEdit
var _list_box: VBoxContainer
var _hint: Label
var _action: Button
var _selected_path := ""
var _built := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.fill_parent(self)
	_build()
	_built = true


func _build() -> void:
	var wash := ColorRect.new()
	wash.color = Color(0.03, 0.035, 0.04, 0.78)
	wash.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(wash)
	UiKit.fill_parent(wash)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	UiKit.fill_parent(centre)

	var frame := UiKit.frame("Saves", "frame")
	frame.custom_minimum_size = Vector2(760, 560)
	centre.add_child(frame)
	var body := UiKit.body(frame) as VBoxContainer

	_title = UiKit.label("Load game", "frame_subheading_label")
	body.add_child(_title)

	_hint = UiKit.label("", "label")
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_hint)

	_name_row = UiKit.row(8)
	_name_row.add_child(UiKit.label("Save name", "label"))
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(420, 0)
	_name_row.add_child(_name_edit)
	body.add_child(_name_row)

	var scroll := UiKit.scroll()
	scroll.custom_minimum_size = Vector2(720, 320)
	body.add_child(scroll)
	_list_box = UiKit.column(4)
	scroll.add_child(_list_box)

	var buttons := UiKit.row(8)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	var cancel := UiKit.button("Cancel", "button")
	cancel.pressed.connect(func() -> void:
		visible = false
		cancelled.emit())
	buttons.add_child(cancel)
	_action = UiKit.button("Load", "menu_button")
	_action.pressed.connect(_on_action)
	buttons.add_child(_action)
	body.add_child(buttons)


func open_save(default_name: String) -> void:
	if not _built:
		await ready
	_mode = "save"
	_title.text = "Save game"
	_hint.text = "Choose a name. Saving under an existing name replaces that save."
	_name_row.visible = true
	_name_edit.text = default_name
	_name_edit.grab_focus()
	_action.text = "Save"
	_action.disabled = false
	_selected_path = ""
	visible = true
	_refresh()


func open_load() -> void:
	if not _built:
		await ready
	_mode = "load"
	_title.text = "Load game"
	_hint.text = "Select a save, then press Load."
	_name_row.visible = false
	_action.text = "Load"
	_selected_path = ""
	_action.disabled = true
	visible = true
	_refresh()


func _refresh() -> void:
	if _list_box == null:
		return
	for child: Node in _list_box.get_children():
		child.queue_free()
	var saves := SaveGame.list_saves()
	if saves.is_empty():
		_list_box.add_child(UiKit.label(
			"No named saves yet. Save a game first.", "label"))
		_action.disabled = true
		return
	for entry: Dictionary in saves:
		var button := UiKit.button(_entry_text(entry), "button")
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.tooltip_text = "Double-click to load"
		button.pressed.connect(_select.bind(entry, button))
		button.gui_input.connect(_on_entry_input.bind(entry, button))
		_list_box.add_child(button)
	if _mode == "load":
		_action.disabled = _selected_path.is_empty()


func _entry_text(entry: Dictionary) -> String:
	var stamp := str(entry.get("saved_at", ""))
	if stamp.is_empty():
		var unix := int(entry.get("modified", 0))
		if unix > 0:
			stamp = Time.get_datetime_string_from_unix_time(unix).replace("T", " ")
	if stamp.is_empty():
		stamp = "unknown date"
	var creative := "  [creative]" if bool(entry.get("creative", false)) else ""
	return "%s%s    seed %d · tick %d · %s" % [
		str(entry.get("name", "Save")), creative, int(entry.get("seed", 0)),
		int(entry.get("tick", 0)), stamp]


func _on_entry_input(event: InputEvent, entry: Dictionary,
		button: Button) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if mouse.double_click and mouse.button_index == MOUSE_BUTTON_LEFT:
		_select(entry, button)
		_action.pressed.emit()


func _select(entry: Dictionary, button: Button) -> void:
	_selected_path = str(entry.get("path", ""))
	_action.disabled = false
	_hint.text = "Selected: %s" % str(entry.get("name", ""))
	for child: Node in _list_box.get_children():
		if child is Button:
			(child as Button).modulate = Color(1, 1, 1, 1) \
				if child == button else Color(0.75, 0.75, 0.75, 1)


func _on_action() -> void:
	if _mode == "save":
		var name := _name_edit.text.strip_edges()
		if name.is_empty():
			_hint.text = "Give the save a name first."
			return
		visible = false
		save_requested.emit(name)
		return
	if _selected_path.is_empty():
		_hint.text = "Select a save first."
		return
	visible = false
	load_requested.emit(_selected_path)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		visible = false
		cancelled.emit()
		get_viewport().set_input_as_handled()
