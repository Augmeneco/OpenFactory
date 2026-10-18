class_name RecipePicker
extends PanelContainer
## The "choose a recipe" panel for assembling machines.
##
## Factorio shows a searchable list of everything the machine's
## ``crafting_categories`` allow and the player has researched; picking one
## writes it into the machine's state.

signal recipe_chosen(recipe_name: String)

const ICON_PIXELS := 36

var world: GameWorld
var simulation: Simulation
var player: Player
var entity: Entity

var _list: GridContainer
var _search: LineEdit
var _count: Label
var _filter := ""


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

	var header := UiKit.row(6)
	header.add_child(UiKit.label("Choose a recipe", "frame_subheading_label"))
	_search = LineEdit.new()
	_search.placeholder_text = "Search"
	_search.custom_minimum_size = Vector2(200, 0)
	_search.text_changed.connect(_on_search)
	header.add_child(_search)
	body.add_child(header)

	_count = UiKit.label("", "label")
	body.add_child(_count)

	var scroll := UiKit.scroll()
	scroll.custom_minimum_size = Vector2(430, 320)
	body.add_child(scroll)

	_list = UiKit.grid(6)
	scroll.add_child(_list)


func open_for(target: Entity) -> void:
	entity = target
	_filter = ""
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
	var names := candidate_recipes()
	_count.text = "%d recipe%s" % [names.size(), "" if names.size() == 1 else "s"]
	if names.is_empty():
		_list.add_child(UiKit.label("Nothing available for this machine yet.",
			"label"))
		return
	for recipe_name: String in names:
		_list.add_child(_recipe_button(recipe_name))


func _recipe_button(recipe_name: String) -> Control:
	var button := Button.new()
	button.custom_minimum_size = Vector2(64, 64)
	# A cell never shows more than its own square, however big the artwork is.
	button.clip_contents = true
	TooltipLayer.attach(button, Tooltips.recipe_card(recipe_name))
	# The icon is a child rather than ``Button.icon`` so it is a real node in
	# the tree, like the inventory slots use.
	var icon := TextureRect.new()
	# EXPAND_IGNORE_SIZE keeps the 64 px icon inside the 52 px box; without it
	# Godot clamps the control to the texture size and it spills out.
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture = FactorioAssets.recipe_icon(
		Prototypes.get_p("recipe", recipe_name), 64)
	icon.set_meta("factorio_icon", "recipe-%s" % recipe_name)
	icon.custom_minimum_size = Vector2(52, 52)
	icon.size = Vector2(52, 52)
	icon.position = Vector2(6, 6)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(icon)
	var normal := FactorioStyle.stylebox("slot", "default")
	if normal != null:
		button.add_theme_stylebox_override("normal", normal)
	var hover := FactorioStyle.stylebox("slot", "hovered")
	if hover != null:
		button.add_theme_stylebox_override("hover", hover)
	var pressed := FactorioStyle.stylebox("slot", "pressed")
	if pressed != null:
		button.add_theme_stylebox_override("pressed", pressed)
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
