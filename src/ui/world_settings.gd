class_name WorldSettingsDialog
extends Control
## Single-player world settings, shown after choosing "Single player".
##
## Factorio exposes map controls before a new map starts; this dialog mirrors
## the parts this generator actually understands: per-resource frequency,
## size and richness, water and moisture/tree density, and the two enemy
## knobs (evolution speed and the initial nest-free distance around spawn).

signal start_requested(settings: Dictionary)
signal cancelled

const ORE_NAMES := ["iron-ore", "copper-ore", "coal", "stone",
	"uranium-ore", "crude-oil"]

var _sliders: Dictionary = {}
var _value_labels: Dictionary = {}
var _formats: Dictionary = {}
var _creative_check: CheckBox
var _built := false


static func default_settings() -> Dictionary:
	var ores: Dictionary = {}
	for ore_name: String in ORE_NAMES:
		ores[ore_name] = {"frequency": 1.0, "size": 1.0, "richness": 1.0}
	return {
		"creative": false,
		"water": 1.0,
		"moisture": 1.0,
		"tree_density": 1.0,
		"evolution_speed": 1.0,
		"nest_distance": 14.0,
		"ores": ores,
	}


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.fill_parent(self)
	_build()
	_built = true
	_reset_defaults()


func open_settings() -> void:
	if not _built:
		await ready
	UiKit.fill_parent(self)
	UiKit.refill(self)
	_reset_defaults()
	visible = true


func _build() -> void:
	# The menu stays behind a dark wash; the frame itself is centred.
	var wash := ColorRect.new()
	wash.color = Color(0.03, 0.035, 0.04, 0.78)
	wash.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(wash)
	UiKit.fill_parent(wash)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	UiKit.fill_parent(centre)

	var frame := UiKit.frame("World settings", "frame")
	frame.custom_minimum_size = Vector2(860, 720)
	centre.add_child(frame)
	var body := UiKit.body(frame) as VBoxContainer

	var intro := UiKit.label(
		"Settings for the next single-player map. They are applied when the map is generated.",
		"label")
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(intro)

	var scroll := UiKit.scroll()
	scroll.custom_minimum_size = Vector2(820, 560)
	body.add_child(scroll)
	var column := UiKit.column(8)
	scroll.add_child(column)

	_add_section(column, "Map")
	_add_slider(column, "Water", "water", 0.0, 2.0, 0.05, 1.0, "x%.2f")
	_add_slider(column, "Moisture / tree density", "moisture",
		0.25, 2.0, 0.05, 1.0, "x%.2f")
	_creative_check = CheckBox.new()
	_creative_check.text = "Creative mode — every technology and recipe unlocked"
	column.add_child(_creative_check)

	_add_section(column, "Ore")
	for ore_name: String in ORE_NAMES:
		var title := UiKit.label(Loc.proto_name("resource", ore_name),
			"frame_subheading_label")
		column.add_child(title)
		_add_slider(column, "Frequency", "ore/%s/frequency" % ore_name,
			0.25, 4.0, 0.05, 1.0, "x%.2f")
		_add_slider(column, "Size", "ore/%s/size" % ore_name,
			0.25, 4.0, 0.05, 1.0, "x%.2f")
		_add_slider(column, "Richness", "ore/%s/richness" % ore_name,
			0.25, 4.0, 0.05, 1.0, "x%.2f")

	_add_section(column, "Enemies")
	_add_slider(column, "Evolution speed", "evolution_speed",
		0.25, 4.0, 0.05, 1.0, "x%.2f")
	_add_slider(column, "Starting nest distance", "nest_distance",
		0.0, 30.0, 1.0, 14.0, "%.0f chunks")

	var buttons := UiKit.row(8)
	buttons.alignment = BoxContainer.ALIGNMENT_END
	var back := UiKit.button("Back", "button")
	back.pressed.connect(func() -> void:
		visible = false
		cancelled.emit())
	buttons.add_child(back)
	var start := UiKit.button("Start game", "menu_button")
	start.pressed.connect(func() -> void:
		start_requested.emit(settings()))
	buttons.add_child(start)
	body.add_child(buttons)


func _add_section(parent: VBoxContainer, title: String) -> void:
	var label := UiKit.label(title, "frame_subheading_label")
	parent.add_child(label)
	parent.add_child(UiKit.hseparator())


func _add_slider(parent: VBoxContainer, label_text: String, key: String,
		minimum: float, maximum: float, step: float, value: float,
		format_string: String) -> void:
	var row := UiKit.row(8)
	var label := UiKit.label(label_text, "label")
	label.custom_minimum_size = Vector2(190, 0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(400, 24)
	row.add_child(slider)
	var value_label := UiKit.label(format_string % value, "label")
	value_label.custom_minimum_size = Vector2(120, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)
	slider.value_changed.connect(func(new_value: float) -> void:
		value_label.text = format_string % new_value)
	_sliders[key] = slider
	_value_labels[key] = value_label
	_formats[key] = format_string
	parent.add_child(row)


func _reset_defaults() -> void:
	var defaults := default_settings()
	if _creative_check != null:
		_creative_check.button_pressed = bool(defaults["creative"])
	for key: String in _sliders:
		var value := 1.0
		if key == "water":
			value = float(defaults["water"])
		elif key == "moisture":
			value = float(defaults["moisture"])
		elif key == "evolution_speed":
			value = float(defaults["evolution_speed"])
		elif key == "nest_distance":
			value = float(defaults["nest_distance"])
		elif key.begins_with("ore/"):
			var parts := key.split("/")
			if parts.size() == 3:
				var ore: Dictionary = defaults["ores"].get(parts[1], {})
				value = float(ore.get(parts[2], 1.0))
		(_sliders[key] as HSlider).value = value
		(_value_labels[key] as Label).text = str(_formats[key] % value)


func settings() -> Dictionary:
	var moisture := float((_sliders["moisture"] as HSlider).value)
	var ores: Dictionary = {}
	for ore_name: String in ORE_NAMES:
		ores[ore_name] = {
			"frequency": float((_sliders["ore/%s/frequency" % ore_name] as HSlider).value),
			"size": float((_sliders["ore/%s/size" % ore_name] as HSlider).value),
			"richness": float((_sliders["ore/%s/richness" % ore_name] as HSlider).value),
		}
	return {
		"creative": _creative_check != null and _creative_check.button_pressed,
		"water": float((_sliders["water"] as HSlider).value),
		"moisture": moisture,
		"tree_density": moisture,
		"evolution_speed": float((_sliders["evolution_speed"] as HSlider).value),
		"nest_distance": float((_sliders["nest_distance"] as HSlider).value),
		"ores": ores,
	}


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		visible = false
		cancelled.emit()
		get_viewport().set_input_as_handled()
