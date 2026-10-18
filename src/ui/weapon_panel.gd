class_name WeaponPanel
extends PanelContainer
## The bottom-left weapon/ammo shortcut panel.
##
## Layout follows Factorio's weapon panel: armour/player button, three weapon
## cells, an armour-grid button and three ammo cells.  The selected gun is
## highlighted green, and the ammo column shows what the current gun will fire.

signal equipment_requested

const SLOT := 44
const GAP := 4
const COLUMNS := 4

var player: Player
var _grid: GridContainer
var _cells: Array[Button] = []
var _icons: Array[TextureRect] = []
var _counts: Array[Label] = []


func _init(player_: Player) -> void:
	player = player_


func _ready() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.08, 0.94)
	style.border_color = Color(0.55, 0.45, 0.25, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(3)
	style.set_content_margin_all(5)
	add_theme_stylebox_override("panel", style)
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(COLUMNS * (SLOT + GAP) + GAP,
		2 * (SLOT + GAP) + GAP)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", GAP)
	_grid.add_theme_constant_override("v_separation", GAP)
	add_child(_grid)
	for i in COLUMNS * 2:
		_add_cell(i)
	if player != null:
		player.inventory_changed.connect(refresh)
		player.equipment_changed.connect(refresh)
	refresh()


func _add_cell(index: int) -> void:
	var button := Button.new()
	button.custom_minimum_size = Vector2(SLOT, SLOT)
	button.focus_mode = Control.FOCUS_NONE
	button.clip_contents = true
	for state: String in ["default", "hovered", "clicked", "disabled"]:
		var box := FactorioStyle.stylebox("slot_button", state)
		if box == null:
			continue
		var key: String = {"default": "normal", "hovered": "hover",
			"clicked": "pressed", "disabled": "disabled"}[state]
		button.add_theme_stylebox_override(key, box)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 4
	icon.offset_top = 4
	icon.offset_right = -4
	icon.offset_bottom = -4
	button.add_child(icon)
	var count := Label.new()
	count.add_theme_font_override("font", FactorioStyle.font("default"))
	count.add_theme_font_size_override("font_size", FactorioStyle.font_size("default"))
	count.add_theme_color_override("font_color", Color(1, 1, 1))
	count.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	count.add_theme_constant_override("outline_size", 4)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	count.set_anchors_preset(Control.PRESET_FULL_RECT)
	count.offset_right = -3
	count.offset_bottom = -1
	button.add_child(count)
	button.pressed.connect(_on_cell_pressed.bind(index))
	_grid.add_child(button)
	_cells.append(button)
	_icons.append(icon)
	_counts.append(count)


func _on_cell_pressed(index: int) -> void:
	if player == null:
		return
	if index == 0 or index == 4:
		# Clicking the armour/player slot wears the best suit that improves on
		# the current one, then opens its equipment grid.  With a suit on the
		# cursor that suit is always the one worn.
		var cursor_name := str(player.cursor_item.get("name", ""))
		var cursor_is_armor := not Prototypes.get_p("armor", cursor_name).is_empty()
		if cursor_is_armor:
			player.equip_armor(cursor_name)
		else:
			var best := player.best_armor_in_inventory()
			var worn := ""
			if player.character != null:
				worn = str(player.character.equipment.armor)
			if not best.is_empty() and (worn.is_empty()
					or Player.armor_order(best) > Player.armor_order(worn)):
				player.equip_armor(best)
		if _has_armor_grid():
			equipment_requested.emit()
		return
	if index >= 1 and index <= 3:
		var guns := _guns()
		var weapon_index := index - 1
		if weapon_index < guns.size():
			player.select_weapon(str(guns[weapon_index]))


func _has_armor_grid() -> bool:
	return player != null and player.character != null \
		and player.character.equipment.width > 0 \
		and player.character.equipment.height > 0


func _guns() -> Array:
	var out: Array = []
	if player == null:
		return out
	var seen: Dictionary = {}
	for slot: Variant in player.inventory.slots:
		if slot == null:
			continue
		var name := str(slot.get("name", ""))
		if seen.has(name) or Prototypes.get_p("gun", name).is_empty():
			continue
		seen[name] = true
		out.append(name)
	out.sort_custom(func(a: String, b: String) -> bool:
		return Prototypes.item_sort_key(a) < Prototypes.item_sort_key(b))
	return out


func _ammo() -> Array:
	var out: Array = []
	if player == null:
		return out
	var gun := player.selected_gun()
	if gun.is_empty():
		return out
	var attack: Dictionary = Prototypes.get_p("gun", gun).get(
		"attack_parameters", {})
	var category := str(attack.get("ammo_category", ""))
	var seen: Dictionary = {}
	for slot: Variant in player.inventory.slots:
		if slot == null:
			continue
		var name := str(slot.get("name", ""))
		var ammo := Prototypes.get_p("ammo", name)
		if ammo.is_empty() or str(ammo.get("ammo_category", "")) != category:
			continue
		if seen.has(name):
			continue
		seen[name] = true
		out.append(name)
	return out


func refresh() -> void:
	if player == null or _cells.is_empty():
		return
	for i in _cells.size():
		_icons[i].texture = null
		_counts[i].text = ""
		_cells[i].modulate = Color(1, 1, 1, 1)
		_cells[i].tooltip_text = ""
	# Player / armour.
	var armor := ""
	if player.character != null:
		armor = str(player.character.equipment.armor)
	# The player button shows the engineer, like Factorio; the armour itself is
	# visible in the separate grid button.
	_icons[0].texture = FactorioAssets.prototype_icon(
		Prototypes.get_p("character", "character"), 64)
	_cells[0].modulate = Color(1, 1, 1, 1) if _has_armor_grid() \
		else Color(0.6, 0.6, 0.6, 1)
	_cells[0].tooltip_text = "Click to wear the best armour and open its grid" \
		if _has_armor_grid() else "Click to wear an armour suit"

	var guns := _guns()
	var selected := player.selected_gun()
	for weapon_index in 3:
		var cell_index := weapon_index + 1
		if weapon_index < guns.size():
			var gun_name := str(guns[weapon_index])
			_icons[cell_index].texture = FactorioAssets.prototype_icon(
				Prototypes.item_proto(gun_name), 64)
			_counts[cell_index].text = str(player.inventory.count_of(gun_name))
			_cells[cell_index].tooltip_text = Loc.proto_name("item", gun_name)
			_cells[cell_index].modulate = Color(0.7, 1.0, 0.7, 1) \
				if gun_name == selected else Color(1, 1, 1, 1)
		else:
			_icons[cell_index].texture = FactorioAssets.prototype_icon(
				Prototypes.item_proto("pistol"), 64)
			_cells[cell_index].modulate = Color(0.35, 0.35, 0.35, 0.55)

	# Armour-grid button: same action as the player button, with a grid mark.
	_icons[4].texture = FactorioAssets.prototype_icon(
		Prototypes.item_proto(armor if not armor.is_empty() else "light-armor"), 64)
	_cells[4].modulate = Color(0.55, 0.55, 0.55, 1) if not _has_armor_grid() \
		else Color(1, 1, 1, 1)
	_cells[4].tooltip_text = "Click to wear the best armour and open its grid" \
		if _has_armor_grid() else "Click to wear an armour suit"

	var ammo_names := _ammo()
	for ammo_index in 3:
		var cell_index := ammo_index + 5
		if ammo_index < ammo_names.size():
			var ammo_name := str(ammo_names[ammo_index])
			_icons[cell_index].texture = FactorioAssets.prototype_icon(
				Prototypes.item_proto(ammo_name), 64)
			_counts[cell_index].text = str(player.inventory.count_of(ammo_name))
			_cells[cell_index].tooltip_text = Loc.proto_name("item", ammo_name)
			_cells[cell_index].modulate = Color(0.7, 1.0, 0.7, 1) \
				if ammo_index == 0 else Color(0.8, 0.8, 0.8, 1)
		else:
			_icons[cell_index].texture = FactorioAssets.prototype_icon(
				Prototypes.item_proto("firearm-magazine"), 64)
			_cells[cell_index].modulate = Color(0.35, 0.35, 0.35, 0.55)
