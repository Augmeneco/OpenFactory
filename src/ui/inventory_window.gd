class_name InventoryWindow
extends Control
## The character screen: crafting menu, inventory grid and crafting queue.
##
## Layout and widgets follow Factorio's character GUI: the recipe list on the
## left, the inventory grid in the middle and the hand-crafting queue beneath
## it.  Slots behave the same way too — left click moves a whole stack through
## the cursor, right click moves half.

const INVENTORY_COLUMNS := 10
const SLOT_PIXELS := 40
const CRAFT_COLUMNS := 8

var player: Player
## The open machine window, when there is one; Shift moves player stacks there.
var entity_window: EntityWindow

var _root_frame: PanelContainer
var _inventory_grid: GridContainer
var _queue_row: HBoxContainer
var _recipe_grid: GridContainer
var _search: LineEdit
var _cursor_icon: TextureRect
var _hint: Label
var _slots: Array = []
var _recipe_buttons: Array = []
var _filter := ""
var _craft_group := ""
var _category_row: HBoxContainer
## When the machine window is open beside this one, only that window draws the
## carried-item cursor; this one would duplicate it.
var suppress_cursor := false


func _init(player_: Player) -> void:
	player = player_


func _ready() -> void:
	# Only the window frame itself catches the mouse, not the transparent
	# full-screen overlay: that keeps the quickbar underneath clickable, which
	# is where the "click a slot with an item on the cursor" assignment lives.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.fill_parent(self)
	visible = false
	_build()
	player.inventory_changed.connect(refresh)
	refresh()


func _build() -> void:
	var centre := CenterContainer.new()
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	UiKit.fill_parent(centre)

	_root_frame = UiKit.frame("Character", "frame")
	centre.add_child(_root_frame)
	var body := UiKit.body(_root_frame)

	var columns := UiKit.row(8)
	body.add_child(columns)
	# Factorio puts the character inventory on the left and crafting on the
	# right; the old code had them the other way round.
	columns.add_child(_build_right_side())
	columns.add_child(_build_crafting())

	_cursor_icon = TextureRect.new()
	_cursor_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cursor_icon.custom_minimum_size = Vector2(44, 44)
	_cursor_icon.size = Vector2(44, 44)
	_cursor_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_icon.visible = false
	_cursor_icon.z_index = 100
	add_child(_cursor_icon)


func _build_crafting() -> Control:
	var panel := UiKit.frame("Crafting", "inside_shallow_frame_with_padding")
	var column := UiKit.body(panel) as VBoxContainer

	_search = LineEdit.new()
	_search.placeholder_text = "Search"
	_search.custom_minimum_size = Vector2(320, 0)
	_search.text_changed.connect(func(text: String) -> void:
		_filter = text
		_refresh_recipes())
	column.add_child(_search)
	_category_row = UiKit.row(3)
	column.add_child(_category_row)

	var scroll := UiKit.scroll()
	scroll.custom_minimum_size = Vector2(SLOT_PIXELS * CRAFT_COLUMNS + 24, 420)
	column.add_child(scroll)

	_recipe_grid = UiKit.grid(CRAFT_COLUMNS, 4)
	scroll.add_child(_recipe_grid)
	return panel


func _build_right_side() -> Control:
	var column := UiKit.column(8)

	var inventory_panel := UiKit.frame("Inventory", "inside_shallow_frame_with_padding")
	var inventory_body := UiKit.body(inventory_panel) as VBoxContainer
	_inventory_grid = UiKit.grid(INVENTORY_COLUMNS, 4)
	inventory_body.add_child(_inventory_grid)
	column.add_child(inventory_panel)

	var queue_panel := UiKit.frame("Crafting queue", "inside_shallow_frame_with_padding")
	var queue_body := UiKit.body(queue_panel) as VBoxContainer
	_queue_row = UiKit.row(4)
	queue_body.add_child(_queue_row)
	_hint = UiKit.label("", "label")
	queue_body.add_child(_hint)
	var tip := UiKit.label(
		"Middle-click an item to put it on the selected quickbar slot. "
		+ "Clicking a quickbar slot with an item on the cursor also assigns it.",
		"label")
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	queue_body.add_child(tip)
	column.add_child(queue_panel)

	var close_row := UiKit.row(4)
	close_row.alignment = BoxContainer.ALIGNMENT_END
	var close := UiKit.button("Close", "button")
	close.pressed.connect(close_window)
	close_row.add_child(close)
	column.add_child(close_row)
	return column


# --------------------------------------------------------------------------
# contents
# --------------------------------------------------------------------------

func refresh() -> void:
	_refresh_inventory()
	_refresh_recipes()
	_refresh_queue()
	_refresh_cursor()


func _refresh_inventory() -> void:
	if _inventory_grid == null:
		return
	# Factorio keeps the character inventory grouped by item type; sorting the
	# slots here means the grid, clicking and middle-click assignment all see
	# the same order.
	player.inventory.sort_by_type()
	if _slots.is_empty():
		for i in player.inventory.capacity:
			var slot := ItemSlot.new(SLOT_PIXELS)
			slot.slot_clicked.connect(_on_slot_clicked)
			_inventory_grid.add_child(slot)
			_slots.append(slot)
	for i in _slots.size():
		var slot: ItemSlot = _slots[i]
		slot.bind(player.inventory, i)
		slot.progress = -1.0


func _refresh_recipes() -> void:
	if _recipe_grid == null:
		return
	for child in _recipe_grid.get_children():
		child.queue_free()
	_recipe_buttons.clear()

	var entries := player.craftable_recipes()
	_rebuild_categories(entries)
	for entry: Dictionary in entries:
		if not _craft_group.is_empty() and str(entry.get("group", "")) != _craft_group:
			continue
		if not _filter.is_empty():
			var haystack := ("%s %s" % [entry["name"], entry["product"]]).to_lower()
			if not haystack.contains(_filter.to_lower()):
				continue
		_recipe_grid.add_child(_recipe_button(entry))


func _recipe_button(entry: Dictionary) -> Control:
	var recipe := Prototypes.get_p("recipe", str(entry["name"]))
	var button := Button.new()
	button.custom_minimum_size = Vector2(SLOT_PIXELS, SLOT_PIXELS)
	button.focus_mode = Control.FOCUS_NONE
	TooltipLayer.attach(button, Tooltips.recipe_card(str(entry["name"])))
	button.set_meta("factorio_style", "slot_button")
	# A cell never shows more than its own square, however big the artwork is.
	button.clip_contents = true
	for state: String in ["default", "hovered", "clicked"]:
		var box := FactorioStyle.stylebox("slot_button", state)
		if box != null:
			button.add_theme_stylebox_override(
				String({"default": "normal", "hovered": "hover", "clicked": "pressed"}[state]), box)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	var icon := TextureRect.new()
	# The recipe artwork is 64 px and the slot is 44 px; without this the
	# control takes the texture's size and the icons overlap each other.
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture = FactorioAssets.recipe_icon(recipe, 64)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 2
	icon.offset_top = 2
	icon.offset_right = -2
	icon.offset_bottom = -2
	# Recipes the player cannot afford yet are dimmed, like Factorio's.
	icon.modulate = Color(1, 1, 1, 1) \
		if player.creative or bool(entry["craftable"]) else Color(0.5, 0.5, 0.5, 1)
	button.add_child(icon)
	button.set_meta("factorio_icon", str(entry["product"]))
	button.gui_input.connect(func(event: InputEvent) -> void:
		_on_recipe_input(event, str(entry["name"])))
	_recipe_buttons.append(button)
	return button


func _recipe_tooltip(recipe: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append(Loc.proto_name("recipe", str(recipe.get("name", ""))))
	lines.append("%.2f s" % Prototypes.recipe_energy(recipe))
	for ingredient: Dictionary in Prototypes.recipe_ingredients(recipe):
		lines.append("  %s x%d" % [
			Loc.proto_name(str(ingredient["type"]), str(ingredient["name"])),
			int(ingredient["amount"])])
	lines.append("->")
	for product: Dictionary in Prototypes.recipe_products(recipe):
		lines.append("  %s x%d" % [
			Loc.proto_name(str(product["type"]), str(product["name"])),
			int(product["amount"])])
	return "\n".join(lines)


func _rebuild_categories(entries: Array) -> void:
	if _category_row == null:
		return
	for child in _category_row.get_children():
		child.queue_free()
	var groups: Array = []
	for entry: Dictionary in entries:
		var group := str(entry.get("group", ""))
		if not group.is_empty() and not groups.has(group):
			groups.append(group)
	groups.sort()
	_add_category_button("All", "")
	for group: String in groups:
		_add_category_button(_group_label(group), group)


func _add_category_button(label: String, group: String) -> void:
	var button := UiKit.button(label, "button")
	button.toggle_mode = true
	button.button_pressed = _craft_group == group
	button.custom_minimum_size = Vector2(0, 28)
	button.pressed.connect(_select_craft_group.bind(group))
	_category_row.add_child(button)


func _select_craft_group(group: String) -> void:
	_craft_group = group
	_refresh_recipes()


func _group_label(group: String) -> String:
	var localized := Loc.proto_name("item-group", group)
	if localized.is_empty() or localized == group:
		return group.replace("-", " ").capitalize()
	return localized


func _refresh_queue() -> void:
	if _queue_row == null:
		return
	for child in _queue_row.get_children():
		child.queue_free()
	var shown := 0
	for i in player.craft_queue.size():
		if shown >= 6:
			break
		var entry: Dictionary = player.craft_queue[i]
		var recipe := Prototypes.get_p("recipe", str(entry["recipe"]))
		var slot := ItemSlot.new(SLOT_PIXELS)
		slot.bind(null, -1)
		slot.empty_texture = FactorioAssets.recipe_icon(recipe, 64)
		slot.progress = float(entry["progress"]) if i == 0 else 0.0
		slot.refresh()
		_queue_row.add_child(slot)
		shown += 1
	if player.creative:
		_hint.text = "Creative: click a recipe to take its item directly."
	elif player.craft_queue.is_empty():
		_hint.text = "Nothing queued. Click a recipe to craft it."
	else:
		_hint.text = "%d crafts queued" % player.craft_queue.size()


func _refresh_cursor() -> void:
	if _cursor_icon == null:
		return
	if suppress_cursor:
		_cursor_icon.visible = false
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
	if suppress_cursor and _cursor_icon != null:
		_cursor_icon.visible = false
	elif _cursor_icon != null and _cursor_icon.visible:
		_cursor_icon.position = get_viewport().get_mouse_position() - Vector2(22, 22)
	# The queue advances every frame, so keep its display fresh.
	_refresh_queue_progress()


func _refresh_queue_progress() -> void:
	var index := 0
	for child in _queue_row.get_children():
		if child is ItemSlot:
			(child as ItemSlot).progress = (player.crafting_progress() if index == 0 else 0.0)
			(child as ItemSlot).refresh()
		index += 1


# --------------------------------------------------------------------------
# interaction
# --------------------------------------------------------------------------

func _on_recipe_input(event: InputEvent, recipe_name: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if not button.pressed:
		return
	# The scroll wheel also arrives as a mouse button.  It must not be treated
	# as a left click on the recipe, or scrolling the crafting list silently
	# queues more items.
	if button.button_index != MOUSE_BUTTON_LEFT \
			and button.button_index != MOUSE_BUTTON_RIGHT:
		return
	var count := 1
	if button.button_index == MOUSE_BUTTON_RIGHT:
		count = maxi(1, player.craftable_count(Prototypes.get_p("recipe", recipe_name)))
	elif button.shift_pressed:
		# Shift queues a short batch; Ctrl+Shift uses the recursive maximum.
		if button.ctrl_pressed:
			count = maxi(1, player.craftable_count(
				Prototypes.get_p("recipe", recipe_name)))
		else:
			count = 5
	if player.creative:
		var products := Prototypes.recipe_products(
			Prototypes.get_p("recipe", recipe_name))
		if not products.is_empty():
			var product := str(products[0].get("name", ""))
			if button.button_index == MOUSE_BUTTON_RIGHT:
				count = maxi(1, Prototypes.stack_size(product))
			player.creative_give(product, count)
		refresh()
		return
	player.craft(recipe_name, count)
	refresh()


func _on_slot_clicked(slot: ItemSlot, button: int, shift: bool, _ctrl: bool) -> void:
	if slot.inventory == null:
		return
	var stack := slot.stack()
	var held := player.cursor_item

	# Middle click copies the item onto the selected quickbar slot, which is
	# how an item from anywhere in the inventory gets onto the bar.
	if button == MOUSE_BUTTON_MIDDLE:
		if stack.is_empty():
			return
		player.assign_quickbar_slot(str(stack["name"]))
		return

	# Shift-click is Factorio's quick transfer: whole stack (or half with the
	# right button) goes to the other open inventory.  With the character
	# inventory alone open there is nowhere to send it, so the normal click
	# behaviour stays.
	if shift and held.is_empty() and not stack.is_empty() \
			and entity_window != null and entity_window.visible:
		var item_name := str(stack["name"])
		var amount := int(stack["count"])
		if button == MOUSE_BUTTON_RIGHT:
			amount = maxi(1, amount / 2)
		var moved := entity_window.receive_from_player(item_name, amount)
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
			_transfer(slot, str(held["name"]), int(held["count"]))
	elif button == MOUSE_BUTTON_RIGHT:
		if held.is_empty():
			if stack.is_empty():
				return
			var half: int = maxi(1, int(stack["count"]) / 2) if not shift else int(stack["count"])
			half = mini(half, int(stack["count"]))
			var taken := slot.inventory.extract(str(stack["name"]), half)
			player.cursor_item = {"name": str(stack["name"]), "count": taken}
		else:
			_transfer(slot, str(held["name"]), 1)
	slot.refresh()
	player.inventory_changed.emit()
	refresh()

## Move as much of ``amount`` of ``item_name`` from the cursor into a slot.
func _transfer(slot: ItemSlot, item_name: String, amount: int) -> void:
	var target: Variant = slot.inventory.slots[slot.slot_index]
	if target != null and str(target["name"]) != item_name:
		return
	# `insert` returns the *leftover*, not the amount that went in.  Using the
	# leftover as if it were the inserted count kept the cursor full while the
	# inventory also grew, which duplicated the stack on every click.
	var leftover := slot.inventory.insert(item_name, amount)
	var inserted := amount - leftover
	var left := int(player.cursor_item.get("count", 0)) - inserted
	if left > 0:
		player.cursor_item = {"name": item_name, "count": left}
	else:
		player.cursor_item = {}


# --------------------------------------------------------------------------
# visibility
# --------------------------------------------------------------------------

func open_window() -> void:
	visible = true
	refresh()


func close_window() -> void:
	visible = false
	suppress_cursor = false
	# Whatever is on the cursor stays there: closing the window is exactly how
	# Factorio lets you carry an item out of the inventory and place it in the
	# world.  The HUD draws the held item while the window is closed.


## Used by the game to lay this window beside an open machine window.
func frame_size() -> Vector2:
	return _root_frame.size if _root_frame != null else Vector2.ZERO


func place_frame(position_: Vector2) -> void:
	if _root_frame != null:
		_root_frame.position = position_


func toggle() -> void:
	if visible:
		close_window()
	else:
		open_window()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			close_window()
			accept_event()
