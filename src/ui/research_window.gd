class_name ResearchWindow
extends Control
## The research screen, laid out like Factorio's.
##
## Left: what is being studied now, the card of whatever is selected, and a
## scrollable list of every technology.  Right: the technology tree, cards in
## tiers with connector lines.  Clicking a card anywhere selects it; the button
## on the selected card starts or cancels the research.

const LIST_COLUMNS := 7

var research: Research
var player: Player

var tree: ResearchTree
var _window: PanelContainer
var _selected := ""
var _list: GridContainer
var _detail: VBoxContainer
var _current_label: Label
var _current_bar: ProgressBar
var _cancel_button: Button
var _only_main: CheckBox
var _scroll: ScrollContainer
var _list_scroll: ScrollContainer


func _init(research_: Research, player_: Player) -> void:
	research = research_
	player = player_


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.fill_parent(self)
	visible = false
	_build()
	refresh()
	research.research_changed.connect(refresh)
	research.availability_changed.connect(refresh)


func _build() -> void:
	var wash := ColorRect.new()
	wash.color = Color(0, 0, 0, 0.35)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wash)
	UiKit.fill_parent(wash)

	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	UiKit.fill_parent(centre)

	_window = UiKit.frame("Research", "technology_gui_outer_frame")
	if FactorioStyle.stylebox("technology_gui_outer_frame", "default") == null:
		_window = UiKit.frame("Research", "frame")
	centre.add_child(_window)
	var body := UiKit.body(_window) as VBoxContainer

	var columns := UiKit.row(8)
	body.add_child(columns)

	columns.add_child(_build_left())
	columns.add_child(_build_right())


## The queue, the selected card and the list of everything.
func _build_left() -> Control:
	var panel := UiKit.frame("Research queue", "technology_gui_left_frame")
	if FactorioStyle.stylebox("technology_gui_left_frame", "default") == null:
		panel = UiKit.frame("Research queue", "inside_shallow_frame_with_padding")
	var column := UiKit.body(panel) as VBoxContainer
	column.custom_minimum_size = Vector2(360, 0)

	var queue := UiKit.column(3)
	column.add_child(queue)
	_current_label = UiKit.label("Nothing being researched", "label")
	queue.add_child(_current_label)
	var bar_row := UiKit.row(4)
	_current_bar = ProgressBar.new()
	_current_bar.show_percentage = false
	_current_bar.custom_minimum_size = Vector2(240, 10)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.85, 0.35, 0.95)
	_current_bar.add_theme_stylebox_override("fill", fill)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0, 0, 0, 0.55)
	_current_bar.add_theme_stylebox_override("background", back)
	bar_row.add_child(_current_bar)
	_cancel_button = UiKit.button("Cancel", "research_queue_cancel_button")
	if FactorioStyle.stylebox("research_queue_cancel_button", "default") == null:
		_cancel_button = UiKit.button("Cancel", "button")
	_cancel_button.pressed.connect(func() -> void:
		research.cancel()
		refresh())
	bar_row.add_child(_cancel_button)
	queue.add_child(bar_row)

	column.add_child(UiKit.hseparator())
	# The selected technology's card, which is where Start lives.
	_detail = UiKit.column(4)
	column.add_child(_detail)

	column.add_child(UiKit.hseparator())
	column.add_child(UiKit.label("Technology list", "frame_subheading_label"))
	_list_scroll = UiKit.scroll()
	_list_scroll.custom_minimum_size = Vector2(340, 180)
	column.add_child(_list_scroll)
	_list = UiKit.grid(LIST_COLUMNS, 3)
	_list_scroll.add_child(_list)
	return panel


## The tree itself.
func _build_right() -> Control:
	var panel := UiKit.frame("Technology tree", "technology_graph_title_frame")
	if FactorioStyle.stylebox("technology_graph_title_frame", "default") == null:
		panel = UiKit.frame("Technology tree", "inside_shallow_frame_with_padding")
	var column := UiKit.body(panel) as VBoxContainer

	var head := UiKit.row(6)
	_only_main = CheckBox.new()
	_only_main.text = "Show only technologies that unlock something"
	_only_main.toggled.connect(func(on: bool) -> void:
		if tree != null:
			tree.set_only_main(on))
	head.add_child(_only_main)
	var close := UiKit.button("Close", "button")
	close.pressed.connect(close_window)
	head.add_child(close)
	column.add_child(head)

	_scroll = UiKit.scroll()
	# UiKit's scroll helper disables horizontal scrolling, which would make the
	# container grow to the tree's full 3900 px width instead of clipping it.
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# Sized to leave the whole window inside a 1600x900 viewport.
	_scroll.custom_minimum_size = Vector2(800, 470)
	column.add_child(_scroll)

	tree = ResearchTree.new()
	tree.set_research(research)
	tree.technology_selected.connect(_on_selected)
	tree.technology_chosen.connect(_on_chosen)
	_scroll.add_child(tree)
	return panel


# --------------------------------------------------------------------------
# refresh
# --------------------------------------------------------------------------

func refresh() -> void:
	_refresh_queue()
	if tree != null:
		tree.refresh()
	_rebuild_list()
	_refresh_detail()


func _refresh_queue() -> void:
	if _current_label == null:
		return
	if research.current.is_empty():
		_current_label.text = "Nothing being researched"
		_current_bar.value = 0.0
		_cancel_button.disabled = true
		return
	_current_label.text = "%s  (%d/%d units, %.0fs each)" % [
		Loc.proto_name("technology", research.current), research.units_done,
		research.total_units(), research.unit_time()]
	_current_bar.value = research.progress() * 100.0
	_cancel_button.disabled = false


## The list of every technology, as small cards, which is how the original lets
## you find one without hunting through the graph.
func _rebuild_list() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		child.queue_free()
	# Put everything that can be started right now above the already researched
	# and prerequisite-locked technologies.  The available group keeps the
	# research window's own cheap-first ordering.
	var available: Array = research.available_technologies()
	var available_set: Dictionary = {}
	for name: String in available:
		available_set[name] = true
	for name: String in available:
		_list.add_child(_card(name, 40))
	for name: String in Prototypes.all("technology"):
		if not available_set.has(name):
			_list.add_child(_card(name, 40))


func _card(name: String, pixels: float) -> Control:
	var button := Button.new()
	button.custom_minimum_size = Vector2(pixels, pixels)
	button.clip_contents = true
	button.focus_mode = Control.FOCUS_NONE
	button.set_meta("technology", name)
	button.tooltip_text = _tooltip(name)
	var state := tree.style_for(name) if tree != null \
		else "unavailable_technology_slot"
	for slot: String in ["default", "hovered"]:
		var box := FactorioStyle.stylebox(state, slot)
		if box == null:
			box = FactorioStyle.stylebox("slot", slot)
		if box != null:
			button.add_theme_stylebox_override(
				"normal" if slot == "default" else "hover", box)
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture = FactorioAssets.icon_for("technology", name, 64)
	icon.set_meta("factorio_icon", "technology-%s" % name)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 2
	icon.offset_top = 2
	icon.offset_right = -2
	icon.offset_bottom = -2
	button.add_child(icon)
	button.pressed.connect(func() -> void: _on_selected(name))
	return button


## The selected technology's card: cost, result and the Start button.
func _refresh_detail() -> void:
	if _detail == null:
		return
	for child in _detail.get_children():
		child.queue_free()
	if _selected.is_empty():
		_detail.add_child(UiKit.label("Select a technology.", "label"))
		return
	var proto := Prototypes.get_p("technology", _selected)
	var header := UiKit.row(6)
	var big := TextureRect.new()
	big.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	big.custom_minimum_size = Vector2(56, 56)
	big.texture = FactorioAssets.icon_for("technology", _selected, 64)
	big.set_meta("factorio_icon", "technology-%s" % _selected)
	big.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	header.add_child(big)
	var titles := UiKit.column(1)
	titles.add_child(UiKit.label(Loc.proto_name("technology", _selected),
		"tooltip_title_label"))
	var status := "Researched" if research.is_researched(_selected) \
		else ("Unlocked by doing: %s" % research.trigger_description(_selected)
			if research.is_trigger(_selected) else "Not researched")
	titles.add_child(UiKit.label(status, "label"))
	header.add_child(titles)
	_detail.add_child(header)

	var description := Loc.proto_description(proto)
	if not description.is_empty():
		var text := UiKit.label(description, "tooltip_label")
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.custom_minimum_size = Vector2(340, 0)
		_detail.add_child(text)

	var unit := research.unit_of(_selected)
	if not unit.is_empty():
		_detail.add_child(UiKit.label("Cost", "frame_subheading_label"))
		var cost := UiKit.row(4)
		for ingredient: Variant in unit.get("ingredients", []):
			if not (ingredient is Array) or (ingredient as Array).size() < 2:
				continue
			cost.add_child(_cost_chip(str(ingredient[0]), int(ingredient[1])))
		_detail.add_child(cost)

	var unlocked: Array = []
	for effect: Variant in proto.get("effects", []):
		if effect is Dictionary and str(effect.get("type", "")) == "unlock-recipe":
			unlocked.append(str(effect.get("recipe", "")))
	if not unlocked.is_empty():
		_detail.add_child(UiKit.label("Result", "frame_subheading_label"))
		var results := UiKit.grid(6, 4)
		for recipe_name: String in unlocked:
			var chip := TextureRect.new()
			chip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			chip.custom_minimum_size = Vector2(40, 40)
			chip.texture = FactorioAssets.recipe_icon(
				Prototypes.get_p("recipe", recipe_name), 64)
			chip.set_meta("factorio_icon", "recipe-%s" % recipe_name)
			chip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			chip.tooltip_text = Loc.proto_name("recipe", recipe_name)
			results.add_child(chip)
		_detail.add_child(results)

	# The action button.
	if research.is_researched(_selected):
		var done := UiKit.button("Researched", "button")
		done.disabled = true
		_detail.add_child(done)
	elif research.is_trigger(_selected):
		var trigger := UiKit.button("Unlocks by playing", "button")
		trigger.disabled = true
		_detail.add_child(trigger)
	elif research.current == _selected:
		var stop := UiKit.button("Cancel research", "red_button")
		if FactorioStyle.stylebox("red_button", "default") == null:
			stop = UiKit.button("Cancel research", "button")
		stop.pressed.connect(func() -> void:
			research.cancel()
			refresh())
		_detail.add_child(stop)
	else:
		var start := UiKit.button("Start research", "button")
		start.disabled = not research.is_available(_selected)
		start.pressed.connect(func() -> void:
			research.start(_selected)
			refresh())
		_detail.add_child(start)


## A science pack with its amount, as the cost line shows them.
func _cost_chip(item_name: String, amount: int) -> Control:
	var box := UiKit.row(2)
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = Vector2(28, 28)
	icon.texture = FactorioAssets.prototype_icon(Prototypes.item_proto(item_name), 64)
	icon.set_meta("factorio_icon", "item-%s" % item_name)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.tooltip_text = Loc.proto_name("item", item_name)
	box.add_child(icon)
	box.add_child(UiKit.label("x%d" % amount, "label"))
	return box


func _tooltip(name: String) -> String:
	var lines := PackedStringArray()
	lines.append(Loc.proto_name("technology", name))
	var unit := research.unit_of(name)
	if not unit.is_empty():
		lines.append("%d units, %.0fs each" % [int(unit.get("count", 0)),
			float(unit.get("time", 0.0))])
		for entry: Variant in unit.get("ingredients", []):
			if entry is Array and (entry as Array).size() >= 2:
				lines.append("  %s x%d" % [Loc.proto_name("item", str(entry[0])),
					int(entry[1])])
	for effect: Variant in Prototypes.get_p("technology", name).get("effects", []):
		if effect is Dictionary and str(effect.get("type", "")) == "unlock-recipe":
			lines.append("Unlocks: %s" % Loc.proto_name("recipe",
				str(effect.get("recipe", ""))))
	return "\n".join(lines)


# --------------------------------------------------------------------------
# interaction
# --------------------------------------------------------------------------

func _on_selected(name: String) -> void:
	_selected = name
	_refresh_detail()


## Clicking a card in the tree starts it if it can be started.
func _on_chosen(name: String) -> void:
	_selected = name
	if not research.is_researched(name) and not research.is_trigger(name) \
			and research.is_available(name):
		research.start(name)
	refresh()


func open_window() -> void:
	visible = true
	refresh()


func close_window() -> void:
	visible = false


func toggle() -> void:
	if visible:
		close_window()
	else:
		open_window()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close_window()
			accept_event()
