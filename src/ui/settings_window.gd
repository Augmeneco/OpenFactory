class_name SettingsWindow
extends Control
## Global audio and rendering settings.
##
## The sliders apply immediately; the game persists their values in
## user://settings.json.  The tile threshold is expressed in the same units as
## the camera zoom: at or below it, terrain is drawn from cached chunks.

signal changed(values: Dictionary)
signal closed

const DEFAULTS := {
	"sound_volume": 0.9,
	"music_volume": 0.85,
	"tile_lod_zoom": 0.70,
	"tutorial_enabled": true,
}

var _sliders: Dictionary = {}
var _value_labels: Dictionary = {}
var _tutorial_check: CheckBox
var _syncing := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.fill_parent(self)
	_build()


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

	var frame := UiKit.frame("Settings", "frame")
	frame.custom_minimum_size = Vector2(680, 500)
	centre.add_child(frame)
	var body := UiKit.body(frame) as VBoxContainer

	var intro := UiKit.label(
		"Changes apply immediately. Audio and rendering settings are saved for the next launch.",
		"label")
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(intro)

	_add_section(body, "Tutorial")
	_tutorial_check = CheckBox.new()
	_tutorial_check.text = "Show tutorial objectives"
	_tutorial_check.tooltip_text = "Hide the objective chain and its notifications."
	_tutorial_check.toggled.connect(func(_on: bool) -> void:
		if not _syncing:
			changed.emit(values()))
	body.add_child(_tutorial_check)
	var tutorial_note := UiKit.label(
		"Disables the objective chain without deleting its saved progress.",
		"label")
	tutorial_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tutorial_note)

	_add_section(body, "Audio")
	_add_slider(body, "Sound volume", "sound_volume", 0.0, 1.0, 0.05,
		0.9, "%d%%", true)
	_add_slider(body, "Music volume", "music_volume", 0.0, 1.0, 0.05,
		0.85, "%d%%", true)

	_add_section(body, "Rendering")
	_add_slider(body, "Simplify terrain at zoom ≤", "tile_lod_zoom",
		0.20, 1.00, 0.05, 0.70, "%.2f×", false)
	var note := UiKit.label(
		"At or below this camera zoom, individual terrain tiles are replaced by cached simplified chunks. Lower values keep detailed tiles longer; 0.20× only simplifies when fully zoomed out.",
		"label")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(note)

	body.add_child(UiKit.spacer(8.0))
	var buttons := UiKit.row(8)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	var close := UiKit.button("Back", "button")
	close.pressed.connect(close_settings)
	buttons.add_child(close)
	body.add_child(buttons)


func _add_section(parent: VBoxContainer, title: String) -> void:
	parent.add_child(UiKit.spacer(8.0))
	parent.add_child(UiKit.label(title, "frame_subheading_label"))
	parent.add_child(UiKit.hseparator())


func _add_slider(parent: VBoxContainer, label_text: String, key: String,
		minimum: float, maximum: float, step: float, value: float,
		format_string: String, percent: bool) -> void:
	var row := UiKit.row(8)
	var label := UiKit.label(label_text, "label")
	label.custom_minimum_size = Vector2(230, 0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(320, 24)
	row.add_child(slider)
	var value_label := UiKit.label(_format(value, format_string, percent), "label")
	value_label.custom_minimum_size = Vector2(76, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)
	slider.value_changed.connect(func(new_value: float) -> void:
		value_label.text = _format(new_value, format_string, percent)
		if not _syncing:
			changed.emit(values()))
	_sliders[key] = slider
	_value_labels[key] = value_label
	parent.add_child(row)


static func _format(value: float, format_string: String, percent: bool) -> String:
	if percent:
		return format_string % int(round(value * 100.0))
	return format_string % value


func open_settings(values: Dictionary) -> void:
	_syncing = true
	if _tutorial_check != null:
		_tutorial_check.button_pressed = bool(values.get(
			"tutorial_enabled", DEFAULTS["tutorial_enabled"]))
	for key: String in _sliders:
		var slider: HSlider = _sliders[key]
		slider.value = float(values.get(key, DEFAULTS.get(key, slider.value)))
	_syncing = false
	visible = true
	UiKit.fill_parent(self)
	UiKit.refill(self)


func values() -> Dictionary:
	var out := DEFAULTS.duplicate()
	for key: String in _sliders:
		out[key] = float((_sliders[key] as HSlider).value)
	if _tutorial_check != null:
		out["tutorial_enabled"] = _tutorial_check.button_pressed
	return out


func close_settings() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		close_settings()
		accept_event()
