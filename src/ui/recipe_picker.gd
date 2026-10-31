class_name RecipePicker
extends PanelContainer
## The "choose a recipe" panel for assembling machines.
##
## Factorio shows a searchable list of everything the machine's
## ``crafting_categories`` allow and the player has researched; picking one
## writes it into the machine's state.

signal recipe_chosen(recipe_name: String)

const SLOT_PIXELS := 40
const CRAFT_COLUMNS := 8

var world: GameWorld
var simulation: Simulation
var player: Player
var entity: Entity

var _list: GridContainer
var _search: LineEdit
var _count: Label
var _category_row: HBoxContainer
var _filter := ""
var _group := ""


func _init(world_: GameWorld, simulation_: Simulation, player_: Player) -> void:
	world = world_
	simulation = simulation_
	player = player_


func _ready() -> void:
	var style := FactorioStyle.stylebox("inside_shallow_frame_with_padding", "default")
	if style != null:
		add_theme_stylebox_override("panel", style)

	var body := UiKit.column(6)
	add_child(body)

	_search = LineEdit.new()
	_search.placeholder_text = "Search"
	_search.custom_minimum_size = Vector2(320, 0)
	_search.text_changed.connect(_on_search)
	body.add_child(_search)

	_category_row = UiKit.row(3)
	body.add_child(_category_row)

	_count = UiKit.label("", "label")
	body.add_child(_count)

	var scroll := UiKit.scroll()
	scroll.custom_minimum_size = Vector2(SLOT_PIXELS * CRAFT_COLUMNS + 24, 360)
	body.add_child(scroll)

	_list = UiKit.grid(CRAFT_COLUMNS, 4)
	scroll.add_child(_list)

func open_for(target: Entity) -> void:
	entity = target
	_filter = ""
	_group = ""
	if _search != null:
		_search.text = ""
	visible = true
	_rebuild()


func close_picker() -> void:
	visible = false


func _on_search(text: String) -> void:
	_filter = text.strip_edges().to_lower()
	_rebuild()


## Recipes this machine may run.
##
## Factorio gates the list three ways: the machine's own
## ``crafting_categories``, whether the recipe is unlocked, and whether it is a
## real recipe at all (hidden and parameter recipes are not offered).
func candidate_recipes() -> Array:
	if entity == null:
		return []
	var proto := entity.prototype()
	var categories: Array = []
	var raw: Variant = proto.get("crafting_categories", [])
	if raw is Array:
		categories = raw
	elif raw is String:
		categories = [raw]
	if categories.is_empty():
		return []

	var out: Array = []
	for recipe_name: String in Prototypes.names("recipe"):
		var recipe := Prototypes.get_p("recipe", recipe_name)
		if bool(recipe.get("hidden", false)):
			continue
		if bool(recipe.get("parameter", false)):
			continue
		if not categories.has(str(recipe.get("category", "crafting"))):
			continue
		if player != null and player.research != null \
				and not player.research.is_recipe_unlocked(recipe_name):
			continue
		var products := Prototypes.recipe_products(recipe)
		if products.is_empty():
			continue
		if not _filter.is_empty() \
				and not Loc.proto_name("recipe", recipe_name).to_lower().contains(_filter) \
				and not recipe_name.contains(_filter):
			continue
		out.append(recipe_name)
	out.sort_custom(func(a: String, b: String) -> bool:
		return Loc.proto_name("recipe", a) < Loc.proto_name("recipe", b))
	return out


func _rebuild() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		child.queue_free()
	var all_entries := _candidate_entries()
	_rebuild_categories(all_entries)
	var shown := 0
	for entry: Dictionary in all_entries:
		if not _group.is_empty() and str(entry.get("group", "")) != _group:
			continue
		if not _filter.is_empty():
			var haystack := ("%s %s" % [entry["name"], entry["product"]]).to_lower()
			if not haystack.contains(_filter):
				continue
		_list.add_child(_recipe_button(str(entry["name"])))
		shown += 1
	_count.text = "%d recipe%s" % [shown, "" if shown == 1 else "s"]
	if shown == 0:
		_list.add_child(UiKit.label("Nothing available for this machine yet.",
			"label"))


## Machine recipes as the same {name, product, group, sort_key} records the
## character crafting menu uses, filtered by the machine's own categories and
## the player's research.
func _candidate_entries() -> Array:
	if entity == null:
		return []
	var proto := entity.prototype()
	var categories: Array = []
	var raw: Variant = proto.get("crafting_categories", [])
	if raw is Array:
		categories = raw
	elif raw is String:
		categories = [raw]
	if categories.is_empty():
		return []

	var out: Array = []
	for recipe_name: String in Prototypes.names("recipe"):
		var recipe := Prototypes.get_p("recipe", recipe_name)
		if bool(recipe.get("hidden", false)) or bool(recipe.get("parameter", false)):
			continue
		if not categories.has(str(recipe.get("category", "crafting"))):
			continue
		if player != null and player.research != null \
				and not player.research.is_recipe_unlocked(recipe_name):
			continue
		var products := Prototypes.recipe_products(recipe)
		if products.is_empty():
			continue
		var product := str(products[0].get("name", ""))
		if product.is_empty():
			continue
		out.append({
			"name": recipe_name,
			"product": product,
			"group": Prototypes.item_group(product),
			"sort_key": Prototypes.item_sort_key(product),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["sort_key"]) < str(b["sort_key"]))
	return out


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
	button.button_pressed = _group == group
	button.custom_minimum_size = Vector2(0, 28)
	button.pressed.connect(_select_group.bind(group))
	_category_row.add_child(button)


func _select_group(group: String) -> void:
	_group = group
	_rebuild()


func _group_label(group: String) -> String:
	var localized := Loc.proto_name("item-group", group)
	if localized.is_empty() or localized == group:
		return group.replace("-", " ").capitalize()
	return localized


func _recipe_button(recipe_name: String) -> Control:
	var recipe := Prototypes.get_p("recipe", recipe_name)
	var button := Button.new()
	button.custom_minimum_size = Vector2(SLOT_PIXELS, SLOT_PIXELS)
	button.focus_mode = Control.FOCUS_NONE
	TooltipLayer.attach(button, Tooltips.recipe_card(recipe_name))
	button.set_meta("factorio_style", "slot_button")
	button.clip_contents = true
	for state: String in ["default", "hovered", "clicked"]:
		var box := FactorioStyle.stylebox("slot_button", state)
		if box != null:
			button.add_theme_stylebox_override(
				String({"default": "normal", "hovered": "hover",
					"clicked": "pressed"}[state]), box)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture = FactorioAssets.recipe_icon(recipe, 64)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 2
	icon.offset_top = 2
	icon.offset_right = -2
	icon.offset_bottom = -2
	button.add_child(icon)
	button.pressed.connect(func() -> void:
		_choose(recipe_name))
	return button

func _choose(recipe_name: String) -> void:
	if entity == null:
		return
	# Factorio hands the half-finished ingredients back when the recipe
	# changes; dropping the progress and returning the inputs is the same
	# thing without a spill on the ground.
	if float(entity.state.get("progress", 0.0)) > 0.0:
		_refund(entity)
	entity.state["recipe"] = recipe_name
	entity.state["progress"] = 0.0
	entity.state["consumed"] = false
	recipe_chosen.emit(recipe_name)
	close_picker()


static func _refund(target: Entity) -> void:
	var recipe := Prototypes.get_p("recipe", str(target.state.get("recipe", "")))
	if recipe.is_empty():
		return
	var input := InventoryLayout.get_inventory(target, InventoryLayout.INPUT)
	if input == null:
		return
	for ingredient: Dictionary in Prototypes.recipe_ingredients(recipe):
		if str(ingredient.get("type", "item")) == "fluid":
			continue
		input.insert(str(ingredient["name"]), int(ingredient["amount"]))


func _tooltip(recipe_name: String) -> String:
	var recipe := Prototypes.get_p("recipe", recipe_name)
	var lines := PackedStringArray()
	lines.append(Loc.proto_name("recipe", recipe_name))
	for ingredient: Dictionary in Prototypes.recipe_ingredients(recipe):
		lines.append("  %s x%s" % [Loc.proto_name(_kind(ingredient), str(ingredient["name"])),
			_format(float(ingredient["amount"]))])
	lines.append("->")
	for product: Dictionary in Prototypes.recipe_products(recipe):
		lines.append("  %s x%s" % [Loc.proto_name(_kind(product), str(product["name"])),
			_format(float(product["amount"]))])
	lines.append("%.1f s" % Prototypes.recipe_energy(recipe))
	return "\n".join(lines)


static func _kind(entry: Dictionary) -> String:
	return "fluid" if str(entry.get("type", "item")) == "fluid" else "item"


static func _format(value: float) -> String:
	return str(int(value)) if is_equal_approx(value, roundf(value)) \
		else "%.1f" % value


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close_picker()
			accept_event()
