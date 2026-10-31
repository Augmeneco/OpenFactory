class_name SaveLoadDialog
extends Control
## Named save browser.  One dialog serves both "Save game" (name + existing
## saves) and "Load game" (pick one of the named saves), so the pause menu and
## the title screen share the same files and layout.

signal save_requested(name: String)
signal load_requested(path: String)
signal save_deleted(path: String)
signal cancelled

var _mode := "load"
var _title: Label
var _name_row: HBoxContainer
var _name_edit: LineEdit
var _list_box: VBoxContainer
var _hint: Label
var _action: Button
var _save_current: Button
var _delete: Button
var _confirm_delete: ConfirmationDialog
var _pending_delete_path := ""
var _pending_delete_name := ""
var _current_name := ""
var _current_path := ""
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
	_delete = UiKit.button("Delete", "button")
	_delete.disabled = true
	_delete.pressed.connect(_on_delete)
	buttons.add_child(_delete)
	_save_current = UiKit.button("Save current", "button")
	_save_current.visible = false
	_save_current.pressed.connect(_on_save_current)
	buttons.add_child(_save_current)
	var cancel := UiKit.button("Cancel", "button")
	cancel.pressed.connect(func() -> void:
		visible = false
		cancelled.emit())
	buttons.add_child(cancel)
	_action = UiKit.button("Load", "menu_button")
	_action.pressed.connect(_on_action)
	buttons.add_child(_action)
	body.add_child(buttons)

	_confirm_delete = ConfirmationDialog.new()
	_confirm_delete.title = "Delete save"
	_confirm_delete.ok_button_text = "Delete"
	_confirm_delete.cancel_button_text = "Cancel"
	_confirm_delete.confirmed.connect(_do_delete)
	add_child(_confirm_delete)


func open_save(default_name: String, current_name := "",
		current_path := "") -> void:
	if not _built:
		await ready
	_mode = "save"
	_title.text = "Save game"
	_current_name = current_name
	_current_path = current_path
	_hint.text = "Choose a name. Saving under an existing name replaces that save."
	_name_row.visible = true
	# Opening the dialog on an already-loaded save pre-selects that name, so
	# Save simply overwrites it instead of creating another factory.
	_name_edit.text = current_name if not current_name.is_empty() else default_name
	_name_edit.grab_focus()
	_action.text = "Save"
	_action.disabled = false
	_save_current.visible = true
	_save_current.disabled = current_name.is_empty()
	_selected_path = ""
	_delete.disabled = true
	visible = true
	_refresh()
	_select_current()


func open_load() -> void:
	if not _built:
		await ready
	_mode = "load"
	_title.text = "Load game"
	_hint.text = "Select a save, then press Load."
	_name_row.visible = false
	_action.text = "Load"
	_save_current.visible = false
	_selected_path = ""
	_action.disabled = true
	_delete.disabled = true
	visible = true
	_refresh()


func _refresh() -> void:
	if _list_box == null:
		return
	_delete.disabled = true
	for child: Node in _list_box.get_children():
		child.queue_free()
	var saves := SaveGame.list_saves()
	if saves.is_empty():
		_list_box.add_child(UiKit.label(
			"No named saves yet. Save a game first.", "label"))
		_action.disabled = _mode == "load"
		return
	for entry: Dictionary in saves:
		var button := UiKit.button(_entry_text(entry), "button")
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.tooltip_text = "Double-click to load" if _mode == "load" \
			else "Double-click to overwrite this save"
		button.set_meta("save_path", str(entry.get("path", "")))
		button.set_meta("save_entry", entry)
		button.pressed.connect(_select.bind(entry, button))
		button.gui_input.connect(_on_entry_input.bind(entry, button))
		_list_box.add_child(button)
	if _mode == "load":
		_action.disabled = _selected_path.is_empty()
	if _selected_path.is_empty():
		_delete.disabled = true


## Highlight the save the game was loaded from, if it is in the list.
func _select_current() -> void:
	if _current_path.is_empty():
		return
	for child: Node in _list_box.get_children():
		if child is Button and str(child.get_meta("save_path", "")) == _current_path:
			_select(child.get_meta("save_entry"), child as Button)
			return


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
	_delete.disabled = false
	if _mode == "save":
		# Clicking a save in save mode adopts its name; the Save button then
		# overwrites that file instead of creating a new one.
		_name_edit.text = str(entry.get("name", ""))
		_hint.text = "Selected: %s — Save overwrites it." % str(entry.get("name", ""))
	else:
		_hint.text = "Selected: %s" % str(entry.get("name", ""))
	for child: Node in _list_box.get_children():
		if child is Button:
			(child as Button).modulate = Color(1, 1, 1, 1) \
				if child == button else Color(0.75, 0.75, 0.75, 1)


## Save straight into the save the game came from, without touching the name.
func _on_save_current() -> void:
	if _current_name.is_empty():
		_hint.text = "No current save to overwrite. Give this one a name first."
		return
	visible = false
	save_requested.emit(_current_name)


func _on_delete() -> void:
	if _selected_path.is_empty():
		return
	var entry_name := _name_edit.text.strip_edges()
	if _mode == "load":
		entry_name = _selected_path.get_file().get_basename()
	# Prefer the selected row's displayed name when deleting from the browser.
	if _list_box != null:
		for child: Node in _list_box.get_children():
			if child is Button and str(child.get_meta("save_path", "")) == _selected_path:
				var entry: Variant = child.get_meta("save_entry", {})
				if entry is Dictionary:
					entry_name = str((entry as Dictionary).get("name", entry_name))
				break
	_pending_delete_path = _selected_path
	_pending_delete_name = entry_name
	_confirm_delete.dialog_text = "Delete save '%s'?\nThis cannot be undone." % entry_name
	_confirm_delete.popup_centered()


func _do_delete() -> void:
	if _pending_delete_path.is_empty():
		return
	var path := _pending_delete_path
	var name := _pending_delete_name
	_pending_delete_path = ""
	_pending_delete_name = ""
	if not SaveGame.delete_save(path):
		_hint.text = "Could not delete %s." % name
		return
	if path == _current_path:
		_current_path = ""
		_current_name = ""
		_save_current.disabled = true
	_selected_path = ""
	_delete.disabled = true
	_action.disabled = _mode == "load"
	_hint.text = "Deleted %s." % name
	_refresh()
	save_deleted.emit(path)


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
