class_name ItemPicker
extends PanelContainer
## The item list for an empty quickbar slot.
##
## Unlike the inventory grid, it offers every item the current research has
## unlocked, not just the ones already in the player's pockets.  Picking one
## writes it into the slot; if the player owns none, placing it makes a ghost.

signal item_chosen(item_name: String)

const COLUMNS := 8

var player: Player
var slot_index := -1

var _list: GridContainer
var _search: LineEdit
var _count: Label
var _filter := ""


func _init(player_: Player) -> void:
	player = player_


func _ready() -> void:
	visible = false
	z_index = 60
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(560, 400)
	# A solid dark window: the shared inside-frame texture is mostly
	# transparent, which left the grid floating over the world.
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.08, 0.97)
	style.border_color = Color(0.55, 0.45, 0.25, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	add_theme_stylebox_override("panel", style)

	var body := UiKit.column(6)
	add_child(body)

	var header := UiKit.row(6)
	header.add_child(UiKit.label("Choose an item", "frame_subheading_label"))
	_search = LineEdit.new()
	_search.placeholder_text = "Search"
	_search.custom_minimum_size = Vector2(220, 0)
	_search.text_changed.connect(_on_search)
	header.add_child(_search)
	var close := UiKit.button("Close", "button")
	close.pressed.connect(close_picker)
	header.add_child(close)
	body.add_child(header)

	_count = UiKit.label("", "label")
	body.add_child(_count)

	var scroll := UiKit.scroll()
	scroll.custom_minimum_size = Vector2(520, 300)
	body.add_child(scroll)
	_list = UiKit.grid(COLUMNS, 4)
	scroll.add_child(_list)


func open_for(slot: int) -> void:
	slot_index = slot
	_filter = ""
	if _search != null:
		_search.text = ""
	visible = true
	_rebuild()
	call_deferred("_place")


func close_picker() -> void:
	visible = false


func _place() -> void:
	if not visible:
		return
	var view := get_viewport_rect().size
	size = get_combined_minimum_size()
	position = (view - size) * 0.5 - Vector2(0, 120)


func _on_search(text: String) -> void:
	_filter = text.strip_edges().to_lower()
	_rebuild()


## Every item unlocked by research, plus whatever the player carries.  Recipes
## are the unlock gate Factorio uses, so an item is available when a recipe
## that produces it is researched.
func candidate_items() -> Array:
	var found: Dictionary = {}
	if player != null and player.research != null:
		for recipe_name: String in Prototypes.names("recipe"):
			var recipe := Prototypes.get_p("recipe", recipe_name)
			if bool(recipe.get("hidden", false)) or bool(recipe.get("parameter", false)):
				continue
			if not player.research.is_recipe_unlocked(recipe_name):
				continue
			for product: Dictionary in Prototypes.recipe_products(recipe):
				if str(product.get("type", "item")) != "item":
					continue
				var name := str(product.get("name", ""))
				if not name.is_empty():
					found[name] = true
	if player != null:
		for slot: Variant in player.inventory.slots:
			if slot is Dictionary:
				found[str(slot.get("name", ""))] = true
		if player.creative:
			# Creative is not limited by recipes: every real item prototype is
			# available in the picker.
			for proto_type: String in Prototypes.ITEM_LIKE_TYPES:
				for name: String in Prototypes.names(proto_type):
					var proto := Prototypes.get_p(proto_type, name)
					if not bool(proto.get("hidden", false)):
						found[name] = true
	for name: String in found.keys():
		if name.is_empty():
			found.erase(name)
			continue
		var proto := Prototypes.item_proto(name)
		if proto.is_empty() or bool(proto.get("hidden", false)):
			found.erase(name)
	var out: Array = found.keys()
	out.sort_custom(func(a: String, b: String) -> bool:
		return Prototypes.item_sort_key(a) < Prototypes.item_sort_key(b))
	return out


func _rebuild() -> void:
	if _list == null:
		return
	for child: Node in _list.get_children():
		child.queue_free()
	var names := candidate_items()
	if not _filter.is_empty():
		var filtered: Array = []
		for name: String in names:
			if name.contains(_filter) \
					or Loc.proto_name("item", name).to_lower().contains(_filter):
				filtered.append(name)
		names = filtered
	_count.text = "%d item%s" % [names.size(), "" if names.size() == 1 else "s"]
	if names.is_empty():
		_list.add_child(UiKit.label("Nothing unlocked yet.", "label"))
		return
	for name: String in names:
		_list.add_child(_item_button(name))


func _item_button(item_name: String) -> Control:
	var button := Button.new()
	button.custom_minimum_size = Vector2(52, 52)
	button.clip_contents = true
	button.tooltip_text = Loc.proto_name("item", item_name)
	button.pressed.connect(func() -> void:
		item_chosen.emit(item_name)
		close_picker())
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = FactorioAssets.prototype_icon(
		Prototypes.item_proto(item_name), 64)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 4
	icon.offset_top = 4
	icon.offset_right = -4
	icon.offset_bottom = -4
	button.add_child(icon)
	return button
