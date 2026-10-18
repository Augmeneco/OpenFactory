class_name EntityWindow
extends Control
## The window for whatever machine the player opened.
##
## A chest shows its slots, a furnace shows input, output and fuel, an
## assembling machine adds its current recipe and progress.  Slot behaviour is
## the shared ``ItemSlot`` one, so the cursor carries stacks between the
## machine and the character exactly as in Factorio.

const SLOT_PIXELS := 40
const COLUMNS := 8

var world: GameWorld
var simulation: Simulation
var player: Player

var entity: Entity
var _frame: PanelContainer
var _title: Label
var _body: VBoxContainer
var _sections: Array = []          ## [{ inventory, title, grid, slots }]
var _fluid_box: VBoxContainer
var _fluid_labels: Array = []
var _cursor_icon: TextureRect
var _recipe_row: HBoxContainer
var _recipe_icon: TextureRect
var _recipe_label: Label
var _recipe_button: Button
var _request_box: VBoxContainer
var _request_slots: Array = []
var picker: RecipePicker
var _status: Label
## Train sections: a stop's name, or a locomotive's schedule.
## Set when the window is showing a train rather than a placed machine.
var train: Dictionary = {}
var _train_box: VBoxContainer
var _station_field: LineEdit
var _schedule_field: LineEdit
var _automatic: CheckBox
## The rocket silo's own controls.
var _rocket_box: VBoxContainer
var _rocket_status: Label
var _rocket_bar: ProgressBar
var _launch_button: Button
var _close_row: HBoxContainer
var _progress: ProgressBar


func _init(world_: GameWorld, simulation_: Simulation, player_: Player) -> void:
	world = world_
	simulation = simulation_
	player = player_


func _ready() -> void:
	# The full-screen root must not eat clicks meant for the character
	# inventory beside it.  Only the machine frame catches the mouse.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.fill_parent(self)
	visible = false
	_build()


func _build() -> void:
	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	UiKit.fill_parent(centre)

	_frame = UiKit.frame("Machine", "frame")
	_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	centre.add_child(_frame)
	_body = UiKit.body(_frame) as VBoxContainer
	_title = _body.get_child(0) as Label
	_title.mouse_filter = Control.MOUSE_FILTER_STOP

	_status = UiKit.label("", "label")
	_body.add_child(_status)

	_progress = ProgressBar.new()
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(260, 10)
	_progress.max_value = 100.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.85, 0.35, 0.95)
	_progress.add_theme_stylebox_override("fill", fill)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0, 0, 0, 0.55)
	_progress.add_theme_stylebox_override("background", back)
	_body.add_child(_progress)

	# Trains: a stop is named here, and a locomotive's schedule is written out
	# one station per line.
	# A rocket silo needs a launch button and a count of the parts on the pad.
	_rocket_box = UiKit.column(3)
	_rocket_box.visible = false
	_body.add_child(_rocket_box)
	_rocket_status = UiKit.label("", "label")
	_rocket_box.add_child(_rocket_status)
	_rocket_bar = ProgressBar.new()
	_rocket_bar.show_percentage = false
	_rocket_bar.custom_minimum_size = Vector2(260, 12)
	var rocket_fill := StyleBoxFlat.new()
	rocket_fill.bg_color = Color(0.55, 0.75, 1.0, 0.95)
	_rocket_bar.add_theme_stylebox_override("fill", rocket_fill)
	var rocket_back := StyleBoxFlat.new()
	rocket_back.bg_color = Color(0, 0, 0, 0.55)
	_rocket_bar.add_theme_stylebox_override("background", rocket_back)
	_rocket_box.add_child(_rocket_bar)
	_launch_button = UiKit.button("Launch rocket", "green_button")
	if FactorioStyle.stylebox("green_button", "default") == null:
		_launch_button = UiKit.button("Launch rocket", "button")
	_launch_button.pressed.connect(_on_launch_pressed)
	_rocket_box.add_child(_launch_button)

	_train_box = UiKit.column(4)
	_train_box.visible = false
	_body.add_child(_train_box)

	var station_row := UiKit.row(4)
	station_row.add_child(UiKit.label("Station name", "label"))
	_station_field = LineEdit.new()
	_station_field.custom_minimum_size = Vector2(180, 0)
	_station_field.text_submitted.connect(func(text: String) -> void:
		if entity != null:
			entity.state["station"] = text
			_tooltip_refresh())
	station_row.add_child(_station_field)
	_train_box.add_child(station_row)

	_automatic = CheckBox.new()
	_automatic.text = "Automatic"
	_automatic.toggled.connect(func(on: bool) -> void:
		_set_automatic(on))
	_train_box.add_child(_automatic)

	_train_box.add_child(UiKit.label("Schedule (one station per line)", "label"))
	_schedule_field = LineEdit.new()
	_schedule_field.custom_minimum_size = Vector2(240, 0)
	_schedule_field.text_submitted.connect(func(text: String) -> void:
		_set_schedule(text))
	_train_box.add_child(_schedule_field)

	_close_row = UiKit.row(4)
	_close_row.alignment = BoxContainer.ALIGNMENT_END
	var close_row := _close_row
	var close := UiKit.button("Close", "button")
	close.pressed.connect(close_window)
	close_row.add_child(close)
	_body.add_child(close_row)

	_fluid_box = UiKit.column(3)
	_body.add_child(_fluid_box)
	_body.move_child(_fluid_box, _body.get_child_count() - 2)

	# Requester and buffer chests get a request list the player fills in with
	# whatever is on the cursor.
	_request_box = UiKit.column(4)
	_body.add_child(_request_box)
	_body.move_child(_request_box, _body.get_child_count() - 2)

	# The recipe row: what the machine is set to make, and a way to change it.
	_recipe_row = UiKit.row(6)
	_recipe_icon = TextureRect.new()
	_recipe_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_recipe_icon.custom_minimum_size = Vector2(40, 40)
	_recipe_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_recipe_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_recipe_row.add_child(_recipe_icon)
	_recipe_label = UiKit.label("", "label")
	_recipe_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipe_row.add_child(_recipe_label)
	_recipe_button = UiKit.button("Set recipe", "button")
	_recipe_button.pressed.connect(_open_picker)
	_recipe_row.add_child(_recipe_button)
	_body.add_child(_recipe_row)
	_body.move_child(_recipe_row, _body.get_child_count() - 2)

	picker = RecipePicker.new(world, simulation, player)
	picker.visible = false
	picker.recipe_chosen.connect(_on_recipe_chosen)
	add_child(picker)

	_cursor_icon = TextureRect.new()
	_cursor_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cursor_icon.custom_minimum_size = Vector2(44, 44)
	_cursor_icon.size = Vector2(44, 44)
	_cursor_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_icon.z_index = 100
	_cursor_icon.visible = false
	add_child(_cursor_icon)


# --------------------------------------------------------------------------
# contents
# --------------------------------------------------------------------------

## Show the silo's launch controls only when a silo is open.
func _refresh_rocket() -> void:
	if _rocket_box == null or entity == null:
		return
	var is_silo := entity.proto_type == "rocket-silo"
	_rocket_box.visible = is_silo
	if not is_silo or simulation == null:
		return
	var parts := simulation.rocket_parts(entity)
	var required := Simulation.rocket_parts_required()
	_rocket_status.text = "Rocket parts: %d / %d   |   %d launched" % [
		parts, required, int(entity.state.get("launches", 0))]
	_rocket_bar.max_value = float(required)
	_rocket_bar.value = float(mini(parts, required))
	_launch_button.disabled = not simulation.rocket_ready(entity)
	_launch_button.text = "Launch rocket" if not simulation.rocket_ready(entity) \
		else "Launch!"


func _on_launch_pressed() -> void:
	if simulation == null or entity == null:
		return
	var result := simulation.launch_rocket(entity)
	print("rocket launch: %s" % [result])
	refresh()


## Show the train controls only for the two prototypes that have them.
func _refresh_train() -> void:
	if _train_box == null:
		return
	var is_stop := entity.proto_type == "train-stop"
	var train := _train_of(entity)
	var is_locomotive := not train.is_empty()
	_train_box.visible = is_stop or is_locomotive
	_station_field.get_parent().visible = is_stop
	_automatic.visible = is_locomotive
	_schedule_field.visible = is_locomotive
	_schedule_field.get_parent().get_child(1).visible = is_locomotive
	if is_stop:
		_station_field.text = str(entity.state.get("station", "Station"))
	if is_locomotive:
		_automatic.set_pressed_no_signal(bool(train.get("automatic", false)))
		_schedule_field.text = "\n".join(train.get("schedule", []))


## Open the window on a train rather than on a machine standing in the world.
func open_train(target: Dictionary) -> void:
	train = target
	entity = null
	_sections.clear()
	_fluid_labels.clear()
	_train_box.visible = true
	_station_field.get_parent().visible = false
	_automatic.visible = true
	_schedule_field.visible = true
	_schedule_field.get_parent().get_child(1).visible = true
	_title.text = Loc.proto_display_name(
		Prototypes.get_p("locomotive", "locomotive"), "locomotive")
	# The title and the Close button stay; a train has no inventory, status or
	# progress to show.
	for child in _body.get_children():
		if child != _train_box and child != _title and child != _close_row:
			child.visible = false
	_title.visible = true
	_close_row.visible = true
	_status.visible = false
	_progress.visible = false
	_automatic.set_pressed_no_signal(bool(train.get("automatic", false)))
	_schedule_field.text = "\n".join(train.get("schedule", []))
	visible = true


## The sound of whatever lid the machine has, if the prototype declares one.
func _play_lid(open: bool) -> void:
	if entity == null:
		return
	var proto := entity.prototype()
	var reference: Variant = proto.get("open_sound" if open else "close_sound")
	if reference == null:
		return
	FactorioAudio.play_at(reference, Vector2(entity.center()))


func open_window(target: Entity) -> void:
	entity = target
	if _title != null:
		_title.text = Loc.proto_display_name(target.prototype(), target.name)
		TooltipLayer.attach(_title, Tooltips.entity_card(target))
	_rebuild_sections()
	visible = true
	refresh()
	_play_lid(true)


func close_window() -> void:
	if picker != null:
		picker.close_picker()
	if visible:
		_play_lid(false)
	visible = false
	entity = null
	# An item on the cursor stays on the cursor; the player may be carrying it
	# out of the machine to place it somewhere else.
	player.inventory_changed.emit()


func toggle_window(target: Entity) -> void:
	if visible and entity == target:
		close_window()
	else:
		open_window(target)


## Used by the game to lay this window beside the player's inventory.
func frame_size() -> Vector2:
	return _frame.size if _frame != null else Vector2.ZERO


func place_frame(position_: Vector2) -> void:
	if _frame != null:
		_frame.position = position_


func _rebuild_sections() -> void:
	for section: Dictionary in _sections:
		(section["container"] as Node).queue_free()
	_sections.clear()
	_rebuild_fluid_rows()
	_rebuild_recipe_row()
	_rebuild_requests()

	var layout := InventoryLayout.for_entity(entity)
	var order := [InventoryLayout.INPUT, InventoryLayout.FUEL,
		InventoryLayout.OUTPUT, InventoryLayout.STORAGE, InventoryLayout.MODULES]
	for key: String in order:
		if not layout.has(key):
			continue
		var inventory := InventoryLayout.get_inventory(entity, key)
		if inventory == null or inventory.capacity <= 0:
			continue
		var container := UiKit.column(4)
		container.add_child(UiKit.label(_section_title(key), "frame_subheading_label"))
		var grid := UiKit.grid(COLUMNS, 4)
		container.add_child(grid)
		_body.add_child(container)
		_body.move_child(container, _body.get_child_count() - 2)

		var slots: Array = []
		for i in inventory.capacity:
			var slot := ItemSlot.new(SLOT_PIXELS)
			slot.bind(inventory, i)
			slot.slot_clicked.connect(_on_slot_clicked)
			grid.add_child(slot)
			slots.append(slot)
		_sections.append({
			"key": key, "inventory": inventory, "container": container,
			"grid": grid, "slots": slots,
		})


## The request list of a requester or buffer chest.
##
## Factorio configures these from the chest's window: click a slot and the item
## on your cursor becomes the request.  Slots beyond the requests already set
## are empty and wait for one.
const REQUEST_SLOTS := 12


func _rebuild_requests() -> void:
	for slot: Control in _request_slots:
		slot.queue_free()
	_request_slots.clear()
	if entity == null or _request_box == null:
		return
	var mode := LogisticNetwork.mode_of(entity)
	if mode != LogisticNetwork.MODE_REQUESTER and mode != LogisticNetwork.MODE_BUFFER:
		_request_box.visible = false
		return
	_request_box.visible = true
	_request_box.add_child(UiKit.label("Requests (click with an item on the cursor)",
		"frame_subheading_label"))
	var grid := UiKit.grid(6, 4)
	_request_box.add_child(grid)

	var requests: Dictionary = entity.state.get("requests", {})
	var names: Array = requests.keys()
	names.sort()
	for index in REQUEST_SLOTS:
		var button := Button.new()
		button.custom_minimum_size = Vector2(40, 40)
		var icon := TextureRect.new()
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.custom_minimum_size = Vector2(32, 32)
		icon.size = Vector2(32, 32)
		icon.position = Vector2(4, 4)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(icon)
		var count := Label.new()
		count.position = Vector2(2, 22)
		count.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
		count.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		count.add_theme_constant_override("outline_size", 3)
		count.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(count)
		var style := FactorioStyle.stylebox("slot", "default")
		if style != null:
			button.add_theme_stylebox_override("normal", style)
		var item := str(names[index]) if index < names.size() else ""
		if not item.is_empty():
			icon.texture = FactorioAssets.prototype_icon(Prototypes.item_proto(item), 64)
			icon.set_meta("factorio_icon", "item-%s" % item)
			count.text = str(int(requests[item]))
			button.tooltip_text = "%s  %d" % [Loc.proto_name("item", item),
				int(requests[item])]
		button.set_meta("request_item", item)
		button.pressed.connect(_on_request_clicked.bind(button, MOUSE_BUTTON_LEFT))
		grid.add_child(button)
		_request_slots.append(button)


## Left click sets the request to whatever the cursor holds, or clears the slot
## when the cursor is empty.  Right click adds or removes one stack.
func _on_request_clicked(button: Button, mouse_button: int) -> void:
	if entity == null:
		return
	var requests: Dictionary = entity.state.get("requests", {})
	var slot_item := str(button.get_meta("request_item", ""))
	var held := player.cursor_item
	if mouse_button == MOUSE_BUTTON_RIGHT and not held.is_empty():
		var name := str(held["name"])
		requests[name] = int(requests.get(name, 0)) + Prototypes.stack_size(name)
	elif mouse_button == MOUSE_BUTTON_RIGHT and not slot_item.is_empty():
		var lower: int = int(requests.get(slot_item, 0)) - Prototypes.stack_size(slot_item)
		if lower > 0:
			requests[slot_item] = lower
		else:
			requests.erase(slot_item)
	elif held.is_empty():
		if not slot_item.is_empty():
			requests.erase(slot_item)
	else:
		requests[str(held["name"])] = Prototypes.stack_size(str(held["name"]))
	entity.state["requests"] = requests
	_rebuild_requests()
	refresh()


## The recipe header: icon, name and the button that opens the picker.
func _rebuild_recipe_row() -> void:
	if entity == null or _recipe_row == null:
		return
	if picker != null:
		picker.close_picker()
	var proto := entity.prototype()
	var categories: Variant = proto.get("crafting_categories")
	var can_set := categories is Array and not (categories as Array).is_empty()
	_recipe_row.visible = true
	_recipe_button.visible = can_set

	var recipe_name := str(entity.state.get("recipe", ""))
	# Furnaces have exactly one recipe per category, so they never need the
	# picker; the row still shows what they are smelting.
	if recipe_name.is_empty() and str(proto.get("type", "")) == "furnace":
		recipe_name = _smelting_recipe()
	if recipe_name.is_empty():
		_recipe_icon.texture = null
		_recipe_label.text = "No recipe set" if can_set else "Working"
		return
	_recipe_icon.texture = FactorioAssets.recipe_icon(
		Prototypes.get_p("recipe", recipe_name), 64)
	_recipe_label.text = Loc.proto_name("recipe", recipe_name)


## The single recipe a furnace can run for the ore it is holding.
func _smelting_recipe() -> String:
	var input := InventoryLayout.get_inventory(entity, InventoryLayout.INPUT)
	if input == null:
		return ""
	for slot: Variant in input.slots:
		if slot == null or str(slot.get("name", "")).is_empty():
			continue
		for recipe_name: String in Prototypes.recipes_in_category("smelting"):
			for ingredient: Dictionary in Prototypes.recipe_ingredients(
					Prototypes.get_p("recipe", recipe_name)):
				if str(ingredient["name"]) == str(slot["name"]):
					return recipe_name
	return ""


func _open_picker() -> void:
	if entity == null or picker == null:
		return
	picker.open_for(entity)
	_place_picker()


## Park the picker beside the machine window rather than on top of it.
func _place_picker() -> void:
	if picker == null or _frame == null:
		return
	await get_tree().process_frame
	var viewport := get_viewport_rect().size
	var target := _frame.global_position + Vector2(_frame.size.x + 6.0, 0.0)
	target.x = minf(target.x, maxf(0.0, viewport.x - picker.size.x - 4.0))
	picker.global_position = target


func _on_recipe_chosen(_recipe_name: String) -> void:
	_rebuild_recipe_row()
	refresh()


## One line per fluid box: what is in it, how full and how hot.
func _rebuild_fluid_rows() -> void:
	for label: Node in _fluid_labels:
		label.queue_free()
	_fluid_labels.clear()
	var specs := FluidSystem.box_specs(entity)
	if specs.is_empty():
		_fluid_box.visible = false
		return
	_fluid_box.visible = true
	_fluid_box.add_child(UiKit.label("Fluids", "frame_subheading_label"))
	for spec: Dictionary in specs:
		var label := UiKit.label("", "label")
		label.set_meta("fluid_box", str(spec["name"]))
		_fluid_box.add_child(label)
		_fluid_labels.append(label)


static func _section_title(key: String) -> String:
	match key:
		InventoryLayout.INPUT:
			return "Ingredients"
		InventoryLayout.OUTPUT:
			return "Products"
		InventoryLayout.FUEL:
			return "Fuel"
		InventoryLayout.STORAGE:
			return "Contents"
		InventoryLayout.MODULES:
			return "Modules"
		_:
			return key.capitalize()


## The train this window is looking at, if it is a locomotive.
func _train_of(entity_: Entity) -> Dictionary:
	if not train.is_empty():
		return train
	if simulation == null or simulation.trains == null:
		return {}
	for candidate: Dictionary in simulation.trains.trains:
		if str(candidate.get("lead", "")) == str(entity_.origin):
			return candidate
	return {}


func _set_automatic(on: bool) -> void:
	var train := _train_of(entity)
	if train.is_empty():
		return
	# Taking the throttle by hand hands control back to the driver, as in the
	# original.
	train["automatic"] = on
	train["driven"] = false
	_tooltip_refresh()


func _set_schedule(text: String) -> void:
	var train := _train_of(entity)
	if train.is_empty():
		return
	var names: Array = []
	for line: String in text.split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.is_empty():
			names.append(trimmed)
	train["schedule"] = names
	train["schedule_index"] = 0
	train["automatic"] = not names.is_empty()
	train["wait"] = 0
	_tooltip_refresh()


func _tooltip_refresh() -> void:
	refresh()


func refresh() -> void:
	if entity == null and not train.is_empty():
		# A train has no prototype in the world, so only its own controls show.
		_automatic.set_pressed_no_signal(bool(train.get("automatic", false)))
		var names: Array = train.get("schedule", [])
		if "\n".join(names) != _schedule_field.text:
			_schedule_field.text = "\n".join(names)
		return
	if entity == null:
		return
	var proto := entity.prototype()
	_title.text = Loc.proto_display_name(proto, entity.name)
	_refresh_train()
	_refresh_rocket()

	for section: Dictionary in _sections:
		for slot: ItemSlot in section["slots"]:
			slot.refresh()

	for label: Label in _fluid_labels:
		var box_name := str(label.get_meta("fluid_box", ""))
		var state := simulation.fluids.aggregate(entity, box_name)
		var fluid := str(state["fluid"])
		var amount := float(state["amount"])
		var capacity := maxf(1.0, float(state["capacity"]))
		if fluid.is_empty():
			label.text = "%s: empty" % box_name.capitalize()
			label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			continue
		var hot := ""
		if float(state["temperature"]) > 0.0:
			hot = "  %.0f C" % float(state["temperature"])
		label.text = "%s: %s  %.0f/%.0f%s" % [box_name.capitalize(),
			Loc.proto_name("fluid", fluid), amount, capacity, hot]

	var recipe_name := str(entity.state.get("recipe", ""))
	if not recipe_name.is_empty():
		var recipe := Prototypes.get_p("recipe", recipe_name)
		_status.text = "Recipe: %s" % Loc.proto_name("recipe", recipe_name)
		_progress.visible = true
		_progress.value = float(entity.state.get("progress", 0.0)) * 100.0
	elif entity.proto_type == "mining-drill":
		_status.text = "Mining"
		_progress.visible = true
		_progress.value = float(entity.state.get("progress", 0.0)) * 100.0
	else:
		var satisfaction := simulation.power.satisfaction_for(entity)
		if simulation.power.is_powered(entity):
			_status.text = "Power satisfaction %d%%" % int(satisfaction * 100.0)
		else:
			_status.text = ""
		_progress.visible = false
	_refresh_cursor()


func _refresh_cursor() -> void:
	if _cursor_icon == null:
		return
	var held := player.cursor_item
	if held.is_empty():
		_cursor_icon.visible = false
		return
	_cursor_icon.texture = FactorioAssets.icon_for("item", str(held["name"]), 64)
	_cursor_icon.visible = true


func _process(_delta: float) -> void:
	if not visible:
		return
	if _cursor_icon != null and _cursor_icon.visible:
		_cursor_icon.position = get_viewport().get_mouse_position() - Vector2(22, 22)
	refresh()


func _on_slot_clicked(slot: ItemSlot, button: int, shift: bool, _ctrl: bool) -> void:
	var stack := slot.stack()
	var held := player.cursor_item

	# Shift-click moves a machine stack straight into the character inventory.
	if shift and held.is_empty() and not stack.is_empty():
		var item_name := str(stack["name"])
		var amount := int(stack["count"])
		if button == MOUSE_BUTTON_RIGHT:
			amount = maxi(1, amount / 2)
		var leftover := player.inventory.insert(item_name, amount)
		var moved := amount - leftover
		if moved > 0:
			slot.inventory.extract(item_name, moved)
			slot.refresh()
			player.inventory_changed.emit()
			refresh()
		return

	if button == MOUSE_BUTTON_LEFT:
		if held.is_empty():
			if stack.is_empty():
				return
			player.cursor_item = slot.inventory.take_stack(str(stack["name"]))
		else:
			var leftover := slot.inventory.insert(str(held["name"]), int(held["count"]))
			var inserted := int(held["count"]) - leftover
			var left := int(held["count"]) - inserted
			player.cursor_item = {"name": str(held["name"]), "count": left} if left > 0 else {}
	else:
		if held.is_empty():
			if stack.is_empty():
				return
			var half: int = maxi(1, int(stack["count"]) / 2)
			var taken := slot.inventory.extract(str(stack["name"]), half)
			player.cursor_item = {"name": str(stack["name"]), "count": taken}
		else:
			var one_left := slot.inventory.insert(str(held["name"]), 1)
			if one_left <= 0:
				var left := int(held["count"]) - 1
				player.cursor_item = {"name": str(held["name"]), "count": left} if left > 0 else {}
	slot.refresh()
	refresh()


## Move up to ``amount`` items from the player inventory into this machine.
## Fuel goes to the fuel slot first, ingredients to input/storage; output slots
## are never used for quick transfer.
func receive_from_player(item_name: String, amount: int) -> int:
	if not visible or entity == null or amount <= 0:
		return 0
	var keys: Array = [InventoryLayout.INPUT, InventoryLayout.STORAGE,
		InventoryLayout.MODULES]
	if Energy.is_fuel(item_name):
		keys = [InventoryLayout.FUEL, InventoryLayout.INPUT,
			InventoryLayout.STORAGE, InventoryLayout.MODULES]
	var moved := 0
	var left := amount
	for key: String in keys:
		if left <= 0:
			break
		var inventory := InventoryLayout.get_inventory(entity, key)
		if inventory == null or inventory.capacity <= 0 \
				or not inventory.accepts(item_name):
			continue
		var leftover := inventory.insert(item_name, left)
		var inserted := left - leftover
		moved += inserted
		left = leftover
	return moved

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			close_window()
			accept_event()
