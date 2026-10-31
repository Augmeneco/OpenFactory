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
## Panel order, independent of inventory order.  The first weapon slot is the
## gun the player fires; the first ammo slot is the preferred magazine.
var _weapon_order: Array = []
var _ammo_order: Array = []
var _drag_from := -1
var _drag_kind := ""
var _drag_started := false
var _drag_press_global := Vector2.ZERO
var _suppress_click := false


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
	button.gui_input.connect(_on_cell_gui_input.bind(index))
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
		if _suppress_click:
			_suppress_click = false
			return
		var guns := _guns()
		var weapon_index := index - 1
		if weapon_index < guns.size():
			var gun_name := str(guns[weapon_index])
			# Clicking a slot promotes it to the first slot, which is the
			# active weapon.  Dragging can rearrange the other two.
			_promote(_weapon_order, gun_name)
			player.select_weapon(gun_name)
			refresh()
		return
	if index >= 5 and index <= 7:
		if _suppress_click:
			_suppress_click = false
			return
		var ammo := _ammo()
		var ammo_index := index - 5
		if ammo_index < ammo.size():
			var ammo_name := str(ammo[ammo_index])
			_promote(_ammo_order, ammo_name)
			player.preferred_ammo = ammo_name
			refresh()


## Drag a weapon or ammo icon onto another slot of the same kind.
func _on_cell_gui_input(event: InputEvent, index: int) -> void:
	if not (event is InputEventMouseButton):
		if event is InputEventMouseMotion and _drag_from >= 0:
			if (event as InputEventMouseMotion).relative.length() > 1.0:
				_drag_started = true
		return
	var button := event as InputEventMouseButton
	if button.button_index != MOUSE_BUTTON_LEFT:
		return
	if button.pressed:
		if index in [1, 2, 3, 5, 6, 7]:
			_drag_from = index
			_drag_kind = "weapon" if index <= 3 else "ammo"
			_drag_started = false
			_drag_press_global = get_global_mouse_position()
		return
	_finish_drag()


## Even if the release lands outside the source button, the drag still ends.
func _process(_delta: float) -> void:
	if _drag_from < 0:
		return
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if get_global_mouse_position().distance_to(_drag_press_global) > 4.0:
			_drag_started = true
		return
	_finish_drag()


func _finish_drag() -> void:
	var from := _drag_from
	var kind := _drag_kind
	var started := _drag_started
	_drag_from = -1
	_drag_kind = ""
	_drag_started = false
	if not started:
		return
	var target := _cell_at(get_global_mouse_position())
	if target < 0 or target == from:
		return
	if kind == "weapon" and not (target >= 1 and target <= 3):
		return
	if kind == "ammo" and not (target >= 5 and target <= 7):
		return
	_move_slot(from, target, kind)
	_suppress_click = true
	_clear_suppress_click.call_deferred()


func _clear_suppress_click() -> void:
	_suppress_click = false


func _cell_at(point: Vector2) -> int:
	for index in _cells.size():
		if _cells[index].get_global_rect().has_point(point):
			return index
	return -1


func _move_slot(from: int, to: int, kind: String) -> void:
	# _guns()/_ammo() rebuild and may replace the order array, so take the
	# returned array as the one to mutate.
	var names: Array = _guns() if kind == "weapon" else _ammo()
	var order := names
	var from_index := from - (1 if kind == "weapon" else 5)
	var to_index := to - (1 if kind == "weapon" else 5)
	if from_index < 0 or from_index >= names.size() or to_index < 0:
		return
	var name := str(names[from_index])
	order.erase(name)
	to_index = mini(to_index, order.size())
	order.insert(to_index, name)
	if kind == "weapon":
		player.select_weapon(str(order[0]))
	else:
		player.preferred_ammo = str(order[0])
	refresh()


func _has_armor_grid() -> bool:
	return player != null and player.character != null \
		and player.character.equipment.width > 0 \
		and player.character.equipment.height > 0


func _guns() -> Array:
	var owned: Array = []
	if player == null:
		return owned
	var seen: Dictionary = {}
	for slot: Variant in player.inventory.slots:
		if slot == null:
			continue
		var name := str(slot.get("name", ""))
		if seen.has(name) or Prototypes.get_p("gun", name).is_empty():
			continue
		seen[name] = true
		owned.append(name)
	owned.sort_custom(func(a: String, b: String) -> bool:
		return Prototypes.item_sort_key(a) < Prototypes.item_sort_key(b))
	_weapon_order = _ordered(_weapon_order, owned)
	return _weapon_order


func _ammo() -> Array:
	var owned: Array = []
	if player == null:
		return owned
	var gun := player.selected_gun()
	if gun.is_empty():
		_ammo_order = []
		return owned
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
		owned.append(name)
	_ammo_order = _ordered(_ammo_order, owned)
	return _ammo_order


## Keep the player's order for names that still exist, then append new ones.
static func _ordered(order: Array, owned: Array) -> Array:
	var out: Array = []
	var used: Dictionary = {}
	for name: Variant in order:
		if owned.has(name) and not used.has(name):
			used[name] = true
			out.append(name)
	for name: Variant in owned:
		if not used.has(name):
			used[name] = true
			out.append(name)
	return out


static func _promote(order: Array, name: String) -> void:
	var index := order.find(name)
	if index > 0:
		order.remove_at(index)
		order.push_front(name)


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
	if not guns.is_empty() and player.selected_weapon != str(guns[0]):
		player.select_weapon(str(guns[0]))
	var selected := player.selected_gun()
	for weapon_index in 3:
		var cell_index := weapon_index + 1
		if weapon_index < guns.size():
			var gun_name := str(guns[weapon_index])
			_icons[cell_index].texture = FactorioAssets.prototype_icon(
				Prototypes.item_proto(gun_name), 64)
			_counts[cell_index].text = str(player.inventory.count_of(gun_name))
			_cells[cell_index].tooltip_text = "%s\nClick to select. C / Space fires." % Loc.proto_name("item", gun_name)
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
	if not ammo_names.is_empty() \
			and player.preferred_ammo != str(ammo_names[0]):
		player.preferred_ammo = str(ammo_names[0])
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
