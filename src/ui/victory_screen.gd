class_name VictoryScreen
extends Control
## The screen that comes up when a rocket leaves the pad.
##
## Factorio's own is a quiet card over the world: a heading, a line of text and
## the way back to the factory.  There is nothing to land the rocket on here —
## Space Age's space platforms are not modelled — so the launch itself is the
## ending, which is what the base game's victory is too.

var _window: PanelContainer
var _title: Label
var _body: Label
var _footer: Label
var _launches := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.fill_parent(self)
	visible = false
	_build()


func _build() -> void:
	var wash := ColorRect.new()
	wash.color = Color(0, 0, 0, 0.55)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wash)
	UiKit.fill_parent(wash)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	UiKit.fill_parent(centre)

	_window = UiKit.frame("Rocket launched", "inside_shallow_frame_with_padding")
	centre.add_child(_window)
	var column := UiKit.column(8)
	(_window as PanelContainer).add_child(column)

	_title = UiKit.label("You have launched a rocket", "frame_subheading_label")
	column.add_child(_title)
	_body = UiKit.label("", "label")
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(560, 44)
	column.add_child(_body)
	_footer = UiKit.label("", "label")
	column.add_child(_footer)

	var row := UiKit.row(6)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var keep_playing := UiKit.button("Keep playing", "green_button")
	if FactorioStyle.stylebox("green_button", "default") == null:
		keep_playing = UiKit.button("Keep playing", "button")
	keep_playing.pressed.connect(close_window)
	row.add_child(keep_playing)
	column.add_child(row)


## Show the screen for a launch.  The first one gets the victory text; later
## ones just say how many have gone up.
func announce(number: int, items_per_minute := 0.0) -> void:
	_launches = number
	if number <= 1:
		_title.text = "You have launched a rocket"
		_body.text = "The first rocket has left the pad.  Every drill, furnace, belt and lab led to this."
	else:
		_title.text = "Rocket %d launched" % number
		_body.text = "Another one away."
	_footer.text = "%d rocket%s launched" % [number,
		"" if number == 1 else "s"]
	if items_per_minute > 0.0:
		_footer.text += "   |   %.1f items a minute" % items_per_minute
	visible = true


func close_window() -> void:
	visible = false


func is_open() -> bool:
	return visible


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close_window()
			accept_event()
