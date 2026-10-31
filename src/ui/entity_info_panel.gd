class_name EntityInfoPanel
extends PanelContainer
## The information panel Factorio shows under the minimap while the cursor
## rests on something.
##
## It answers "what is this, and is it happy?": the entity's icon and name, one
## status line (working, no power, output full, no fuel, missing fluid), then
## the numbers the game actually simulates - recipe and crafting speed,
## contents, health, energy use, fuel and the fluid in its pipes.
##
## The panel owns none of the world; `refresh()` is handed the hovered entity
## every frame and rebuilds only when something it shows changed.

const WIDTH := 248.0
## How often the dynamic rows (contents, status) are rebuilt.  A rebuild is a
## handful of labels, but doing it every frame for a full furnace inventory is
## wasteful.
const REFRESH_TICKS := 6

var world: GameWorld
var simulation: Simulation
var player: Player

var _header_icon: TextureRect
var _title: Label
var _status_row: HBoxContainer
var _status_dot: Panel
var _status: Label
var _rows: VBoxContainer
var _hovered: Entity
var _key := ""
var _cooldown := 0


func _init(world_: GameWorld, simulation_: Simulation, player_: Player) -> void:
	world = world_
	simulation = simulation_
	player = player_


func _ready() -> void:
	custom_minimum_size = Vector2(WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := FactorioStyle.stylebox("inside_shallow_frame_with_padding", "default")
	if style == null:
		style = FactorioStyle.stylebox("frame", "default")
	if style != null:
		add_theme_stylebox_override("panel", style)

	var body := UiKit.column(4)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(body)

	var header := UiKit.row(6)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header_icon = TextureRect.new()
	_header_icon.custom_minimum_size = Vector2(32, 32)
	_header_icon.size = Vector2(32, 32)
	_header_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_header_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_header_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_header_icon)
	_title = UiKit.label("", "frame_subheading_label")
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.custom_minimum_size = Vector2(WIDTH - 58, 0)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_title)
	body.add_child(header)

	_status_row = UiKit.row(6)
	_status_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_dot = Panel.new()
	_status_dot.custom_minimum_size = Vector2(10, 10)
	_status_dot.size = Vector2(10, 10)
	_status_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_row.add_child(_status_dot)
	_status = UiKit.label("", "label")
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(WIDTH - 30, 0)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_row.add_child(_status)
	body.add_child(_status_row)

	_rows = UiKit.column(2)
	_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(_rows)
	visible = false


## Point the panel at whatever the cursor is on.  ``null`` hides it.
func refresh(entity: Entity) -> void:
	if entity == null or entity.is_ghost():
		_hovered = null
		_key = ""
		visible = false
		return
	_hovered = entity
	visible = true
	_cooldown -= 1
	var key := _content_key(entity)
	if key == _key and _cooldown > 0:
		return
	_key = key
	_cooldown = REFRESH_TICKS
	_rebuild(entity)


## Show a bare ore tile: Factorio names the resource and how much is left.
func refresh_ore(ore_name: String, amount: float) -> void:
	_hovered = null
	visible = true
	_cooldown = 0
	var key := "ore|%s|%d" % [ore_name, int(amount / 10.0)]
	if key == _key:
		return
	_key = key
	for child: Node in _rows.get_children():
		child.queue_free()
	var resource := Prototypes.get_p("resource", ore_name)
	_title.text = Loc.proto_name("resource", ore_name)
	_header_icon.texture = FactorioAssets.prototype_icon(resource, 64)
	_status.text = "Ore"
	_status.add_theme_color_override("font_color", Color(0.78, 0.74, 0.62))
	var dot_style := StyleBoxFlat.new()
	dot_style.bg_color = Color(0.62, 0.58, 0.48)
	dot_style.set_corner_radius_all(5)
	_status_dot.add_theme_stylebox_override("panel", dot_style)
	_add_row("Amount: %s" % _number(amount))
	if float(resource.get("mining_time", 0.0)) > 0.0:
		_add_row("Mining time: %s s" % _number(
			float(resource.get("mining_time"))))


## Cheap fingerprint of everything the panel shows, so a rebuild only happens
## when the numbers actually move.
func _content_key(entity: Entity) -> String:
	var parts := PackedStringArray()
	parts.append(str(entity.get_instance_id()))
	if simulation != null:
		parts.append(str(int(simulation.tick / 30)))
	parts.append(str(_status_of(entity).get("text", "")))
	var layout := InventoryLayout.for_entity(entity)
	for inventory_name: Variant in layout:
		var inventory := InventoryLayout.get_inventory(entity, str(inventory_name))
		if inventory == null:
			continue
		for slot: Variant in inventory.slots:
			if slot != null:
				parts.append("%s:%s=%d" % [inventory_name, str(slot["name"]),
					int(slot["count"])])
	return "|".join(parts)


func _rebuild(entity: Entity) -> void:
	for child: Node in _rows.get_children():
		child.queue_free()
	var proto := entity.prototype()
	if proto.is_empty():
		_title.text = entity.name
		_status.text = ""
		return
	_title.text = Loc.proto_display_name(proto, entity.name)
	_header_icon.texture = FactorioAssets.prototype_icon(proto, 64)

	var status := _status_of(entity)
	_status.text = status["text"]
	_status.add_theme_color_override("font_color", status["colour"])
	var dot_style := StyleBoxFlat.new()
	dot_style.bg_color = status["colour"]
	dot_style.set_corner_radius_all(5)
	_status_dot.add_theme_stylebox_override("panel", dot_style)

	_add_recipe_rows(entity, proto)
	_add_drill_rows(entity, proto)
	_add_produced_row(entity)
	_add_contents_rows(entity)
	_add_health_row(entity, proto)
	_add_energy_rows(entity, proto)
	_add_fluid_rows(entity)


## One line: is this machine running, and if not, why not.
##
## The reasons are the same ones the simulation refuses to work for, so the
## panel explains the machine instead of only describing it.
func _status_of(entity: Entity) -> Dictionary:
	var proto := entity.prototype()
	var grey := Color(0.62, 0.64, 0.66)
	var green := Color(0.45, 0.86, 0.42)
	var red := Color(0.94, 0.34, 0.30)
	var yellow := Color(0.95, 0.78, 0.25)
	var type_name := str(proto.get("type", entity.proto_type))

	if entity.proto_type == "transport-belt":
		return {"text": "Working", "colour": green}
	if entity.proto_type == "underground-belt":
		var role := str(entity.state.get("io", "input"))
		return {"text": "Input" if role == "input" else "Output",
			"colour": green if world != null \
				and world.underground_partner(entity) != null else grey}
	if entity.proto_type == "splitter":
		return {"text": "Working", "colour": green}
	if entity.proto_type == "inserter":
		var hand: Variant = entity.state.get("hand", {})
		if hand is Dictionary and not (hand as Dictionary).is_empty():
			return {"text": "Carrying %s" % Loc.proto_name("item",
				str((hand as Dictionary).get("name", ""))), "colour": green}
		return {"text": "Idle", "colour": grey}
	if _output_full(entity):
		return {"text": "Output full", "colour": yellow}
	if Energy.is_electric(proto) and Energy.usage(proto) > 0.0 \
			and simulation != null \
			and simulation.power.satisfaction_for(entity) <= 0.0:
		return {"text": "No power", "colour": red}
	if Energy.is_burner(proto):
		var fuel := InventoryLayout.get_inventory(entity, InventoryLayout.FUEL)
		var has_fuel := fuel != null and not fuel.is_empty()
		if not has_fuel and float(entity.state.get("burn_energy", 0.0)) <= 0.0:
			return {"text": "No fuel", "colour": red}
	if simulation != null and int(entity.state.get("working_tick", -1)) \
			== simulation.tick:
		return {"text": "Working", "colour": green}
	if type_name == "mining-drill" and simulation != null \
			and simulation.has_ore_under(entity).is_empty():
		return {"text": "No ore", "colour": grey}
	if type_name in ["furnace", "assembling-machine", "rocket-silo", "lab"]:
		if str(entity.state.get("recipe", "")).is_empty() \
				and type_name != "lab":
			return {"text": "No recipe", "colour": grey}
		return {"text": "Idle", "colour": grey}
	if entity.proto_type in ["container", "logistic-container"]:
		return {"text": LogisticNetwork.mode_of(entity).replace("-", " ").capitalize() \
			if not LogisticNetwork.mode_of(entity).is_empty() else "Storage",
			"colour": green}
	return {"text": "Idle", "colour": grey}


## A crafting machine whose output slot cannot take another product.
func _output_full(entity: Entity) -> bool:
	if str(entity.prototype().get("type", entity.proto_type)) \
			not in ["furnace", "assembling-machine", "rocket-silo", "mining-drill"]:
		return false
	var output := InventoryLayout.get_inventory(entity, InventoryLayout.OUTPUT)
	if output == null or output.is_empty():
		return false
	for slot: Variant in output.slots:
		if slot == null:
			return false
		if int(slot["count"]) < Prototypes.stack_size(str(slot["name"])):
			return false
	return true


## What a mining drill can actually reach: its area and the ore left under it.
func _add_drill_rows(entity: Entity, proto: Dictionary) -> void:
	if str(proto.get("type", "")) != "mining-drill" or world == null:
		return
	var radius := float(proto.get("resource_searching_radius", 2.49))
	var reach := int(ceil(radius))
	var side := reach * 2 + 1
	_add_row("Mining area: %d×%d" % [side, side])
	var categories: Array = proto.get("resource_categories", [])
	var total := 0.0
	var first := ""
	var centre := entity.center()
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var cell := entity.origin + Vector2i(dx, dy)
			var ore := world.ore_at(cell)
			if str(ore["name"]).is_empty() or float(ore["amount"]) <= 0.0:
				continue
			var distance := (Vector2(cell) + Vector2(0.5, 0.5)).distance_to(centre)
			if distance > radius:
				continue
			var resource := Prototypes.get_p("resource", str(ore["name"]))
			if not Simulation._category_matches(resource, categories):
				continue
			total += float(ore["amount"])
			if first.is_empty():
				first = str(ore["name"])
	if first.is_empty():
		_add_row("Expected resources: none")
	else:
		_add_row("Expected resources: %s" % _number(total))
		_add_item_row(first, 1, "resource")


func _add_recipe_rows(entity: Entity, proto: Dictionary) -> void:
	var recipe_name := str(entity.state.get("recipe", ""))
	if recipe_name.is_empty():
		return
	var recipe := Prototypes.get_p("recipe", recipe_name)
	if recipe.is_empty():
		recipe = Prototypes.get_p("recipe", "")
	var speed := float(proto.get("crafting_speed", 1.0))
	_add_row("Recipe: %s" % Loc.proto_name("recipe", recipe_name))
	_add_row("Crafting speed: %s" % _number(speed))
	if not recipe.is_empty():
		var seconds := Prototypes.recipe_energy(recipe) / maxf(speed, 1e-6)
		_add_row("%s every %s s" % [_product_name(recipe), _number(seconds)])


static func _product_name(recipe: Dictionary) -> String:
	var products := Prototypes.recipe_products(recipe)
	if products.is_empty():
		return "product"
	var product: Dictionary = products[0]
	return Loc.proto_name(_kind(product), str(product.get("name", "")))


## Factorio keeps a per-machine production counter for the info panel.
func _add_produced_row(entity: Entity) -> void:
	var produced := int(entity.state.get("produced_total", 0))
	if produced > 0:
		_add_row("Produced: %d" % produced)


func _add_contents_rows(entity: Entity) -> void:
	var entries: Array = []
	for inventory_name: String in [InventoryLayout.INPUT, InventoryLayout.FUEL,
			InventoryLayout.STORAGE]:
		var inventory := InventoryLayout.get_inventory(entity, inventory_name)
		if inventory == null:
			continue
		for slot: Variant in inventory.slots:
			if slot == null:
				continue
			entries.append({"name": str(slot["name"]),
				"count": int(slot["count"]), "from": inventory_name})
	if entries.is_empty():
		return
	_add_row("Contents:", true)
	for entry: Dictionary in entries:
		_add_item_row(str(entry["name"]), int(entry["count"]))


func _add_health_row(entity: Entity, proto: Dictionary) -> void:
	var max_health := float(proto.get("max_health", 0.0))
	if max_health <= 0.0:
		return
	var health := float(entity.state.get("health", max_health))
	_add_row("Health: %s / %s" % [_number(health), _number(max_health)])


func _add_energy_rows(entity: Entity, proto: Dictionary) -> void:
	if Energy.is_electric(proto):
		var usage := Energy.usage(proto)
		if usage > 0.0:
			_add_row("Electric", true)
			_add_row("Max consumption: %s" % Energy.format(usage))
			var drain := Energy.drain(proto)
			if drain > 0.0:
				_add_row("Min consumption: %s" % Energy.format(drain))
	elif Energy.is_burner(proto):
		_add_row("Burner", true)
		var usage := Energy.usage(proto)
		if usage > 0.0:
			_add_row("Max consumption: %s" % Energy.format(usage))


func _add_fluid_rows(entity: Entity) -> void:
	if simulation == null:
		return
	for spec: Dictionary in FluidSystem.box_specs(entity):
		var box_name := str(spec["name"])
		var aggregate: Dictionary = simulation.fluids.aggregate(entity, box_name)
		var fluid := str(aggregate.get("fluid", ""))
		var amount := float(aggregate.get("amount", 0.0))
		if fluid.is_empty():
			continue
		_add_row("Fluid:", true)
		_add_item_row(fluid, int(round(amount)), "fluid")


func _add_row(text: String, heading := false) -> void:
	var label := UiKit.label(text, "label")
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(WIDTH - 24, 0)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if heading:
		label.add_theme_color_override("font_color", Color(0.82, 0.78, 0.62))
	_rows.add_child(label)


## An icon plus its amount, the way Factorio lists furnace contents.
func _add_item_row(item_name: String, count: int, kind := "item") -> void:
	var row := UiKit.row(6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(20, 20)
	icon.size = Vector2(20, 20)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = FactorioAssets.icon_for(kind, item_name, 64)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var label := UiKit.label("%s  %d" % [
		Loc.proto_name(kind, item_name), count], "label")
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	_rows.add_child(row)


static func _kind(entry: Dictionary) -> String:
	return "fluid" if str(entry.get("type", "item")) == "fluid" else "item"


static func _number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	return "%.2f" % value
