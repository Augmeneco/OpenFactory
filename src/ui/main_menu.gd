class_name MainMenu
extends Control
## The title screen, laid out like Factorio's.
##
## The buttons Factorio shows are all here, but only the ones this build can
## actually do are enabled: there is no multiplayer, no map editor and no mod
## portal, so those sit greyed out rather than pretending.

signal new_game_requested
signal continue_requested
signal load_requested
signal settings_requested
signal about_requested
signal quit_requested

const BUTTON_WIDTH := 340
const BUTTON_HEIGHT := 44

var _buttons: VBoxContainer
var _continue_button: Button
var _load_button: Button
var _version: Label


func _ready() -> void:
	# Hidden until the game asks for it; a Control is visible by default and
	# would otherwise sit over everything.
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.fill_parent(self)

	# Factorio's title screen is the game itself behind a dark wash.
	var wash := ColorRect.new()
	wash.color = Color(0.05, 0.05, 0.06, 0.55)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wash)
	UiKit.fill_parent(wash)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	UiKit.fill_parent(centre)

	var column := UiKit.column(0)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	centre.add_child(column)

	var title := Label.new()
	title.text = "OPENFACTORY"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var title_font := FactorioStyle.font("default-game")
	if title_font != null:
		title.add_theme_font_override("font", title_font)
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color(0.98, 0.66, 0.22))
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("outline_size", 8)
	column.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "a Factorio clone  |  data and art read from %s" % \
		str(Prototypes.manifest.get("mods", {}).get("base", "Factorio"))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	column.add_child(subtitle)

	column.add_child(UiKit.spacer(28.0))

	_buttons = UiKit.column(6)
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(_buttons)

	_continue_button = _add("Continue", "menu_button_continue",
		func() -> void: continue_requested.emit())
	_add("Single player", "menu_button", func() -> void: new_game_requested.emit())
	_load_button = _add("Load game", "menu_button",
		func() -> void: load_requested.emit())
	_add_disabled("Multiplayer", "menu_button")
	_add_disabled("Map editor", "menu_button")
	_add("Settings", "menu_button", func() -> void: settings_requested.emit())
	_add_disabled("Mods", "menu_button")
	_add("About", "menu_button", func() -> void: about_requested.emit())
	_add("Quit", "red_button", func() -> void: quit_requested.emit())

	column.add_child(UiKit.spacer(16.0))
	_version = Label.new()
	_version.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_version.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	column.add_child(_version)


func _add(label: String, style_name: String, action: Callable) -> Button:
	var button := UiKit.button(label, style_name)
	button.custom_minimum_size = Vector2(BUTTON_WIDTH, BUTTON_HEIGHT)
	button.pressed.connect(action)
	_buttons.add_child(button)
	return button


## A button for something this build does not have.  Greyed out, not hidden —
## the layout should look like the original.
func _add_disabled(label: String, style_name: String) -> Button:
	var button := _add(label, style_name, func() -> void: pass)
	button.disabled = true
	button.modulate = Color(1, 1, 1, 0.5)
	return button


## Show the menu, with Continue only when there is something to continue.
func open(has_save: bool, version: String) -> void:
	# The title screen is opened both at startup and when quitting a game, and
	# the window may have been resized in between.  Re-apply the full-rect size
	# and force the containers to lay out before the first frame, otherwise the
	# centred column can be left at its zero-size position and the menu shows
	# up as an empty screen.
	visible = true
	UiKit.fill_parent(self)
	UiKit.refill(self)
	if _buttons != null:
		_buttons.queue_sort()
		if _buttons.get_child_count() == 0:
			push_error("MainMenu: no buttons were built")
	_continue_button.disabled = not has_save
	_continue_button.modulate = Color(1, 1, 1, 1 if has_save else 0.5)
	if _load_button != null:
		_load_button.disabled = not has_save
		_load_button.modulate = Color(1, 1, 1, 1 if has_save else 0.5)
	_version.text = version


func close_menu() -> void:
	visible = false
