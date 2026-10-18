class_name Player
extends Node2D
## The player: inventory, quickbar, building and hand mining.
##
## Interaction follows Factorio's conventions: the left mouse button builds
## the selected quickbar item (or a ghost when the item is missing), the right
## button mines whatever is under the cursor, ``R`` rotates the build
## direction, ``Q`` picks the item under the cursor and the number keys choose
## a quickbar slot.

const TILE := 32.0
const REACH_TILES := 10.0

## The quickbar is two rows of ten, as in Factorio, and every slot can be
## reassigned from the inventory.
const QUICKBAR_COLUMNS := 10
const QUICKBAR_SIZE := 20
const QUICKBAR_SLOT := 52
const QUICKBAR_GAP := 4

var world: GameWorld
var simulation: Simulation
var camera: GameCamera
## The engineer the player controls.  Movement, reach and hand mining all come
## from the ``character`` prototype.
var character: Character
## Technology tree; the crafting menu only offers unlocked recipes.
var research: Research

## The engineer's own inventory.  Its base size is the ``character``
## prototype's ``inventory_size``; research can widen it.
var inventory := Inventory.new(0)
var cursor_item: Dictionary = {}       ## held on the cursor, Factorio style
var quickbar: Array = []               ## item name or "" per slot
var selected_slot := 0
var build_direction := 0               ## 16-way direction enum
var hover_cell := Vector2i.ZERO
## Which way the engineer is pointing after a shot, and for how long.
var aim_direction := -1
var _aim_ticks := 0
var hover_valid := false

var _hotbar_ui: GridContainer
var _slot_icons: Array = []
## The red/green wire buttons beside the quickbar, Factorio's shortcut bar.
var _wire_bar: HBoxContainer
var _wire_buttons: Dictionary = {}
## The item list opened by clicking an empty quickbar slot.
var item_picker: ItemPicker
var _click_cooldown := 0.0
var _mouse_right_down := false
## Ctrl-drag copy selection, in cells.
var _copy_anchor := Vector2i.ZERO
var _copy_dragging := false
## Countdown to the next swing sound, so mining does not machine-gun.
var _mining_swing := 0
## Wiring: "" when the hands are free, else the colour being run, plus the
## device the wire is being pulled from.
var wire_colour := ""
## Non-null while the engineer is inside a car.
var driving: Entity = null
## Gun chosen from the bottom-left weapon panel; empty means fall back to the
## quickbar/inventory search.
var selected_weapon := ""
var _wire_from: Entity = null
var _copy_rect := Rect2i()

## Hand crafting, exactly like Factorio's crafting queue: ingredients are
## reserved the moment a craft is queued and the products appear when its
## timer elapses.
var craft_queue: Array = []            ## [{ recipe, count, progress, started }]
## Recipe-name -> recipes that produce it, built lazily for recursive crafting.
var _product_recipes: Dictionary = {}
const MAX_PLANNED_CRAFTS := 10000

signal built(entity: Entity)
signal mined(item_name: String, amount: int)
signal crafted(item_name: String, amount: int)
## Ctrl-click emptied a machine into the inventory.
signal picked_up(amount: int)
## The wire the player is holding, or "" for none.
signal wiring_changed(colour: String)
## The armour or its equipment changed.
signal equipment_changed
signal inventory_changed
signal entity_activated
## A shot went off; the game turns this into a muzzle flash.
signal shot_fired(gun_name: String, ammo_name: String, at: Vector2)
## A blueprint was pasted; the game reports what went up and what is waiting.
signal blueprint_placed(result: Dictionary)
## A train carriage was clicked; the game opens the train's window.
signal train_activated(train: Dictionary)


func _ready() -> void:
	z_index = 100
	refresh_inventory_size()
	give_starting_items()
	_build_quickbar_ui()


## Wire the engineer up so mined items land in this inventory.
func attach_character(engineer: Character) -> void:
	character = engineer
	engineer.mined.connect(_on_mined)
	engineer.mined_entity.connect(_on_mined_entity)


func _on_mined(item_name: String, amount: int) -> void:
	if amount <= 0:
		return
	# The item goes in first.  A sound that fails must never cost the player
	# the ore they just mined.
	var leftover := inventory.insert(item_name, amount)
	FactorioAudio.play_utility("picked_up_item",
		character.position if character != null else hover_cell)
	mined.emit(item_name, amount - leftover)
	if research != null and amount - leftover > 0:
		research.on_item_produced(item_name, amount - leftover)
	inventory_changed.emit()


## Hand mining a machine feeds the "mine-entity" trigger technologies.
func _on_mined_entity(entity_name: String) -> void:
	FactorioAudio.play_utility("deconstruct_small",
		character.position if character != null else hover_cell)
	if research != null:
		research.on_entity_mined(entity_name)


func mining_progress() -> float:
	return character.mining_fraction() if character != null else -1.0


## What the engineer starts with.  This mirrors Factorio's freeplay start:
## enough to smelt iron and copper by hand, which is exactly what the two root
## technologies ask for (produce 50 iron plates / 10 copper plates).
func give_starting_items() -> void:
	var kit := {
		"stone-furnace": 2, "burner-mining-drill": 1, "wooden-chest": 4,
		"transport-belt": 20, "iron-plate": 20, "copper-plate": 10,
		"coal": 50, "wood": 20, "stone": 20, "iron-gear-wheel": 5,
		"pistol": 1, "firearm-magazine": 10,
	}
	for item_name: String in kit:
		# Guns and magazines are item-like but not prototype type "item".
		if Prototypes.is_item(item_name):
			inventory.insert(item_name, int(kit[item_name]))

	quickbar = [
		"stone-furnace", "burner-mining-drill", "transport-belt", "wooden-chest",
		"iron-plate", "copper-plate", "coal", "iron-gear-wheel",
	]
	# Two rows of ten: the starting eight sit in the top row, the rest is
	# deliberately empty so any item from the inventory can be put there.
	while quickbar.size() < QUICKBAR_SIZE:
		quickbar.append("")


# --------------------------------------------------------------------------
# per-frame update
# --------------------------------------------------------------------------

func tick(delta: float) -> void:
	_tick_crafting(delta)
	_tick_mining_sound()
	if character != null:
		character.tick_equipment(delta)
	if camera == null:
		return
	_click_cooldown = maxf(0.0, _click_cooldown - delta)
	if driving != null:
		_tick_driving(delta)
	else:
		_tick_character(delta)

	var mouse_world := camera.mouse_world_position()
	hover_cell = Vector2i(floor(mouse_world / TILE))
	hover_valid = _in_reach(hover_cell)
	if _drag_building:
		_tick_drag_building()
	_tick_mining(delta)
	reposition_quickbar(get_viewport_rect().size)
	queue_redraw()


func _movement_input() -> Vector2:
	var move := Vector2.ZERO
	if input_blocked:
		return move
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		move.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		move.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		move.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		move.y += 1.0
	return move.limit_length(1.0)


## Drive the car in the held direction.  The car is a real world entity, so
## its footprint and collision checks use the same world grid as everything
## else; the engineer rides at its centre.
func _tick_driving(delta: float) -> void:
	if driving == null or character == null:
		return
	var move := _movement_input()
	if move.length_squared() <= 0.0001:
		return
	var speed := 0.14
	var target := driving.center() + move * speed * delta * Simulation.TICKS_PER_SECOND
	var new_origin := Vector2i(
		int(floor(target.x - float(driving.size.x) * 0.5)),
		int(floor(target.y - float(driving.size.y) * 0.5)))
	if not world.move_entity(driving, new_origin):
		return
	driving.direction = Character._direction_from_vector(move)
	character.position = driving.center()
	character.direction = driving.direction
	queue_redraw()


## Enter the nearest car within a few tiles.  F does this while empty-handed.
func enter_vehicle() -> bool:
	if character == null or driving != null:
		return false
	var best: Entity = null
	var best_distance := 5.0
	for car: Entity in world.entities_of_type("car"):
		if car.is_ghost():
			continue
		var distance := car.center().distance_to(character.position)
		if distance < best_distance:
			best_distance = distance
			best = car
	if best == null:
		return false
	driving = best
	character.position = best.center()
	if camera != null:
		camera.follow_target = character.world_position()
		camera.position = character.world_position()
	return true


## Step out on a free side of the car.
func exit_vehicle() -> bool:
	if driving == null or character == null:
		return false
	var car := driving
	var centre := car.center()
	var spots := [Vector2(2, 0), Vector2(-2, 0), Vector2(0, 2),
		Vector2(0, -2), Vector2.ZERO]
	for offset: Vector2 in spots:
		var spot: Vector2 = centre + offset
		if not character.blocked(spot):
			character.position = spot
			break
	driving = null
	if camera != null:
		camera.follow_target = character.world_position()
		camera.position = character.world_position()
	return true


func _tick_character(delta: float) -> void:
	if character == null:
		return
	var move := _movement_input()
	character.tick(move, delta * Simulation.TICKS_PER_SECOND)
	# The camera only rides along while it is following.  Without this check a
	# click on the minimap or an alert released the camera and it snapped back
	# to the engineer on the very next frame, so the map could not be explored
	# and the view appeared to flicker.  Home re-attaches it.
	if camera.follow_target.is_finite():
		camera.follow_target = character.world_position()
		camera.position = character.world_position()


## Right button held mines whatever is under the cursor, taking as long as the
## resource's ``mining_time`` says it should.
func _tick_mining(delta: float) -> void:
	if character == null or driving != null:
		return
	if not _mouse_right_down or input_blocked or not hover_valid:
		character.cancel_mining()
		return
	character.set_mining_target(hover_cell)
	character.advance_mining(delta * Simulation.TICKS_PER_SECOND)


func _in_reach(cell: Vector2i) -> bool:
	if character == null:
		var player_cell := Vector2i(floor(camera.position / TILE))
		return Vector2(player_cell).distance_to(Vector2(cell)) <= REACH_TILES
	return character.within_reach(cell)


## Set by the game while a window is open, so keystrokes do not reach the
## world-building controls underneath.
var input_blocked := false
## Creative worlds let the player take any unlocked item and build without
## spending inventory stacks.
var creative := false
## The character screen is special: it is not modal in Factorio, so an item
## carried out of it can still be placed by clicking the world.  The game keeps
## this in sync; movement and hotkeys stay blocked, mouse clicks do not.
var inventory_open := false
## Left-button drag building.  The game keeps the cursor cell changing while
## the button is held and fills every cell between the last one and the new
## one, which is Factorio's belt-laying gesture.
var _drag_building := false
var _drag_item := ""
var _drag_last := Vector2i(999999, 999999)


func _unhandled_input(event: InputEvent) -> void:
	if input_blocked:
		_drag_building = false
		# While the character screen is open only a world mouse click passes;
		# keys belong to the search box and the inventory itself.
		if not (inventory_open and event is InputEventMouseButton):
			return
	if event is InputEventMouseMotion and _copy_dragging:
		copy_drag(hover_cell, true)
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_RIGHT:
			# A right click also puts the wire tool away, so a forgotten
			# Ctrl+W cannot keep eating left clicks.
			if button.pressed and not wire_colour.is_empty():
				cancel_wire()
				return
			# A right click with something on the cursor puts it back in the
			# inventory, the way Factorio's cursor works.  Otherwise the button
			# is held to mine, because mining takes time.
			if button.pressed and not cursor_item.is_empty():
				return_cursor_item()
				return
			if button.pressed and hover_valid:
				var target := world.entity_at(hover_cell)
				if target != null and target.is_ghost():
					world.remove_entity(target)
					FactorioAudio.play_utility("deconstruct_small", target.center())
					inventory_changed.emit()
					return
				if target != null and target.proto_type == "item-entity":
					_pick_up_ground_item(target)
					return
			_mouse_right_down = button.pressed
			if button.pressed and character != null:
				character.set_mining_target(hover_cell)
			elif character != null:
				character.cancel_mining()
			return
		if not button.pressed:
			if button.button_index == MOUSE_BUTTON_LEFT:
				_drag_building = false
				if _copy_dragging:
					copy_drag(hover_cell, false)
			return
		if button.button_index == MOUSE_BUTTON_LEFT:
			if not wire_colour.is_empty():
				_wire_click()
				return
			if Input.is_key_pressed(KEY_CTRL):
				# Ctrl on a machine empties its output; on bare ground it
				# starts a copy selection, which is where a blueprint begins.
				var under := world.entity_at(hover_cell)
				if under != null and not under.is_ghost():
					take_all_from(under)
				else:
					copy_drag(hover_cell, true)
			else:
				_drag_last = hover_cell
				_drag_item = held_item()
				_drag_building = _can_start_drag()
				build_at_cursor()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode >= KEY_1 and key.keycode <= KEY_9:
			selected_slot = key.keycode - KEY_1
			if key.shift_pressed:
				selected_slot += QUICKBAR_COLUMNS
			_update_quickbar_ui()
		elif key.keycode == KEY_0:
			selected_slot = 9 + (QUICKBAR_COLUMNS if key.shift_pressed else 0)
			_update_quickbar_ui()
		elif key.keycode == KEY_W and key.ctrl_pressed:
			# Keyboard shortcut for the same two buttons beside the quickbar.
			# Plain W is movement; this is Ctrl+W, and the buttons are the
			# discoverable way to take a wire.
			if wire_colour == "":
				wire_colour = CircuitNetwork.RED
			elif wire_colour == CircuitNetwork.RED:
				wire_colour = CircuitNetwork.GREEN
			else:
				wire_colour = ""
			_wire_from = null
			emit_signal("wiring_changed", wire_colour)
			_update_wire_buttons()
			queue_redraw()
		elif key.keycode == KEY_R:
			# R over a placed rotatable entity turns that entity; with bare
			# ground it rotates the item being placed.
			if not _rotate_entity_under_cursor():
				build_direction = posmod(build_direction + 4, 16)
			queue_redraw()
		elif key.keycode == KEY_Q:
			# Q clears the hand wherever the player is; with an empty hand it
			# picks the item under the cursor (and only then needs a target).
			if not cursor_item.is_empty():
				return_cursor_item()
				return
			var q_entity: Entity = null
			var q_ore := ""
			if hover_valid:
				q_entity = world.entity_at(hover_cell)
				q_ore = str(world.ore_at(hover_cell)["name"])
			if q_entity == null and q_ore.is_empty():
				# The hand can also be the selected quickbar slot, not only a
				# cursor stack; Q in empty space puts that away too.
				_clear_hand_selection()
				return
			pick_from_cursor()
		elif key.keycode == KEY_F:
			if driving != null:
				exit_vehicle()
			elif enter_vehicle():
				pass
			else:
				pickup_nearby_items()
		elif key.keycode == KEY_Z:
			drop_cursor_at_pointer()


# --------------------------------------------------------------------------
# building
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# shooting
# --------------------------------------------------------------------------

## The gun the engineer is holding: the quickbar slot if it is one, otherwise
## the best gun in the inventory.
func selected_gun() -> String:
	if not selected_weapon.is_empty() \
			and inventory.count_of(selected_weapon) > 0 \
			and not Prototypes.get_p("gun", selected_weapon).is_empty():
		return selected_weapon
	var held := selected_item()
	if not held.is_empty() and not Prototypes.get_p("gun", held).is_empty():
		return held
	for slot: Variant in inventory.slots:
		if slot == null:
			continue
		var name := str(slot.get("name", ""))
		if not Prototypes.get_p("gun", name).is_empty():
			return name
	return ""


## The inventory size the current research implies.
##
## Factorio's engineer starts with the ``character`` prototype's 80 slots and
## gains ten more from the toolbelt.
## The inventory's size: the character's base, plus research, plus whatever
## the equipment grid's toolbelts add.
func target_inventory_slots() -> int:
	var base := int(Prototypes.get_p("character", "character").get(
		"inventory_size", 80))
	if research != null and research.modifiers != null:
		base += research.modifiers.inventory_slots_bonus()
	# Toolbelt equipment widens the inventory, which is the only reason to
	# wear it.
	if character != null:
		base += int(character.equipment.effects()["inventory_bonus"])
	return base


## Resize the inventory to match the researched slot bonus.
## Put a suit of armour on, returning whatever was being worn.
##
## The old suit keeps its equipment, as it does in Factorio: taking armour off
## does not eject what is plugged into it.
func equip_armor(armor_name: String) -> String:
	if character == null:
		return ""
	var previous := character.equipment.armor
	var from_cursor := str(cursor_item.get("name", "")) == armor_name
	if not from_cursor and inventory.count_of(armor_name) <= 0:
		return previous
	if not previous.is_empty():
		inventory.insert(previous, 1)
	character.equipment.set_armor(armor_name)
	if not armor_name.is_empty():
		if from_cursor:
			var left := int(cursor_item.get("count", 0)) - 1
			cursor_item = {"name": armor_name, "count": left} if left > 0 else {}
		else:
			inventory.extract(armor_name, 1)
	refresh_inventory_size()
	equipment_changed.emit()
	inventory_changed.emit()
	return previous


## Sort key for a suit of armour, matching Factorio's item order.
static func armor_order(armor_name: String) -> String:
	return str(Prototypes.get_p("armor", armor_name).get("order", ""))


## The best suit currently lying in the inventory, or "".
func best_armor_in_inventory() -> String:
	var best := ""
	var best_order := ""
	for slot: Variant in inventory.slots:
		if slot == null:
			continue
		var name := str(slot.get("name", ""))
		if Prototypes.get_p("armor", name).is_empty():
			continue
		var order := armor_order(name)
		if best.is_empty() or order > best_order:
			best = name
			best_order = order
	return best

## Whether a piece of equipment fits in the worn armour right now.
func can_fit_equipment(equipment_name: String) -> bool:
	if character == null:
		return false
	return character.equipment.width > 0 \
		and EquipmentGrid.shape_of(equipment_name).x <= character.equipment.width \
		and EquipmentGrid.shape_of(equipment_name).y <= character.equipment.height


## Plug a piece of equipment into the armour, at a cell if one is given.
func fit_equipment(equipment_name: String, at := Vector2i(-1, -1)) -> bool:
	if character == null or inventory.count_of(equipment_name) <= 0:
		return false
	var placed := false
	if at.x >= 0 and at.y >= 0:
		placed = character.equipment.insert(equipment_name, at)
	else:
		placed = character.equipment.place(equipment_name).x >= 0
	if not placed:
		return false
	inventory.extract(equipment_name, 1)
	refresh_inventory_size()
	equipment_changed.emit()
	return true


## Take a piece of equipment out of the armour and back into the inventory.
func remove_equipment_at(cell: Vector2i) -> String:
	if character == null:
		return ""
	var name := character.equipment.remove_at(cell)
	if name.is_empty():
		return ""
	inventory.insert(name, 1)
	refresh_inventory_size()
	equipment_changed.emit()
	return name


func refresh_inventory_size() -> void:
	var wanted := target_inventory_slots()
	if wanted != inventory.capacity:
		inventory.resize(wanted)
		inventory_changed.emit()


## Choose the gun shown in the bottom-left weapon panel.
func select_weapon(gun_name: String) -> void:
	if gun_name.is_empty() or inventory.count_of(gun_name) <= 0 \
			or Prototypes.get_p("gun", gun_name).is_empty():
		return
	selected_weapon = gun_name
	equipment_changed.emit()
	inventory_changed.emit()


## Ammunition in the inventory that fits a gun's ``ammo_category``.
func ammo_for(gun_name: String) -> String:
	var gun := Prototypes.get_p("gun", gun_name)
	if gun.is_empty():
		return ""
	var category := str(gun.get("attack_parameters", {}).get("ammo_category", ""))
	for slot: Variant in inventory.slots:
		if slot == null:
			continue
		var name := str(slot.get("name", ""))
		var proto := Prototypes.get_p("ammo", name)
		if proto.is_empty():
			continue
		if str(proto.get("ammo_category", "")) == category:
			return name
	return ""


## Fire at the cursor.  Returns ``{ gun, ammo, unit }`` when a shot went off.
##
## The engineer aims at whatever biter is closest to the cursor and inside the
## gun's range, which is what a player pointing at a biter expects to happen.
func shoot_at(cursor_world: Vector2) -> Dictionary:
	if character == null or simulation == null or not character.is_alive():
		return {}
	if character.fire_cooldown > 0:
		return {}
	var gun_name := selected_gun()
	if gun_name.is_empty():
		return {}
	var gun := Prototypes.get_p("gun", gun_name)
	var ammo_name := ammo_for(gun_name)
	if ammo_name.is_empty():
		return {}
	var attack: Variant = gun.get("attack_parameters", {})
	if not (attack is Dictionary):
		return {}
	var range_tiles := float(attack.get("range", 15.0))

	var from := character.position
	var cursor_cell := Vector2(cursor_world) / TILE
	var best: Dictionary = {}
	var best_distance := 1e18
	for unit: Dictionary in simulation.units:
		var position := Vector2(unit["position"])
		if position.distance_to(from) > range_tiles:
			continue
		var to_cursor := position.distance_to(cursor_cell)
		if to_cursor < best_distance:
			best_distance = to_cursor
			best = unit
	if best.is_empty():
		return {}

	var ammo := Prototypes.get_p("ammo", ammo_name)
	var damage := Simulation._attack_damage(ammo.get("ammo_type", {}))
	if damage.is_empty():
		damage = {"amount": 5.0, "type": "physical"}
	# Researched ammunition damage and shooting speed, by ammo category.
	var category := str(ammo.get("ammo_category", ""))
	var modifiers := research.modifiers if research != null else null
	var amount := float(damage["amount"])
	var cooldown := float(attack.get("cooldown", 15))
	if modifiers != null:
		amount *= modifiers.ammo_damage_for(category)
		cooldown /= maxf(0.1, modifiers.gun_speed_for(category))
	inventory.extract(ammo_name, 1)
	character.fire_cooldown = maxi(1, int(round(cooldown)))
	character.shots_fired += 1
	var killed := simulation.damage_unit(best, amount, str(damage["type"]))
	if killed:
		simulation._reap_units()
	aim_direction = Simulation._direction_from_vector(
		Vector2(best["position"]) - from)
	_aim_ticks = 30
	inventory_changed.emit()
	_play_shot_sound(gun_name, ammo_name)
	shot_fired.emit(gun_name, ammo_name, Vector2(best["position"]))
	return {"gun": gun_name, "ammo": ammo_name, "unit": best,
		"killed": killed, "damage": amount, "cooldown": character.fire_cooldown}


func selected_item() -> String:
	if selected_slot < 0 or selected_slot >= quickbar.size():
		return ""
	return str(quickbar[selected_slot])


## The item on the cursor, if it is something that can be put on the ground.
func cursor_placeable_item() -> String:
	var name := str(cursor_item.get("name", ""))
	if name.is_empty():
		return ""
	if name == Blueprints.ITEM:
		return name
	if is_rolling_stock(name) or not placeable_type(name).is_empty():
		return name
	if not tile_item_result(name).is_empty():
		return name
	return ""


## Put the selected quickbar hand away without deleting its shortcut where
## possible: select an empty slot, or clear the slot when every slot is full.
func _clear_hand_selection() -> void:
	if selected_item().is_empty():
		return
	for i in quickbar.size():
		if str(quickbar[i]).is_empty():
			selected_slot = i
			_update_quickbar_ui()
			return
	quickbar[selected_slot] = ""
	_update_quickbar_ui()


## What the next left click will place: whatever is on the cursor, else the
## selected quickbar slot.  This is what lets an item taken out of the
## inventory be built without first copying it onto the quickbar.
func held_item() -> String:
	var on_cursor := cursor_placeable_item()
	if not on_cursor.is_empty():
		return on_cursor
	return selected_item()


## How many of ``item_name`` the hand can actually spend.
func held_count(item_name: String) -> int:
	var count := 0
	if str(cursor_item.get("name", "")) == item_name:
		count = int(cursor_item.get("count", 0))
	else:
		count = inventory.count_of(item_name)
	if count <= 0 and creative and not item_name.is_empty():
		return 1
	return count


## Pick a ground stack up into the inventory.
func _pick_up_ground_item(stack: Entity, make_sound := true) -> int:
	var item_name := str(stack.state.get("item", ""))
	var count := int(stack.state.get("count", 0))
	if item_name.is_empty() or count <= 0:
		world.remove_entity(stack)
		return 0
	var leftover := inventory.insert(item_name, count)
	var taken := count - leftover
	if leftover > 0:
		stack.state["count"] = leftover
	else:
		world.remove_entity(stack)
	if taken > 0:
		if make_sound:
			FactorioAudio.play_utility("picked_up_item", stack.center())
		inventory_changed.emit()
		picked_up.emit(taken)
	return taken


## F: sweep up ground stacks and belt items around the engineer.
const PICKUP_RADIUS := 4.5  # F pick-up radius, in tiles
func pickup_nearby_items() -> int:
	if character == null:
		return 0
	# Entity centres are in tiles; character.position is tiles too.
	var centre := character.position
	var total := 0
	for stack: Entity in world.entities_of_type("item-entity"):
		if stack.center().distance_to(centre) <= PICKUP_RADIUS:
			total += _pick_up_ground_item(stack, false)
	for type_name: String in ["transport-belt", "underground-belt", "splitter"]:
		for belt: Entity in world.entities_of_type(type_name):
			if belt.center().distance_to(centre) > PICKUP_RADIUS:
				continue
			var items := BeltSim.items_of(belt)
			for item: Dictionary in items.duplicate():
				var item_name := str(item.get("name", ""))
				var count := int(item.get("count", 0))
				if item_name.is_empty() or count <= 0:
					continue
				var leftover := inventory.insert(item_name, count)
				var taken := count - leftover
				total += taken
				if leftover > 0:
					item["count"] = leftover
				else:
					items.erase(item)
	if total > 0:
		FactorioAudio.play_utility("picked_up_item", centre)
		inventory_changed.emit()
		picked_up.emit(total)
	return total


## Z: drop the item in hand on the ground under the mouse, or onto a belt.
func drop_cursor_at_pointer() -> int:
	if cursor_item.is_empty():
		return 0
	var item_name := str(cursor_item.get("name", ""))
	var count := int(cursor_item.get("count", 0))
	if item_name.is_empty() or count <= 0:
		return 0
	if not hover_valid or not _in_reach(hover_cell):
		FactorioAudio.play_utility("cannot_build", hover_cell)
		return 0
	var target := world.entity_at(hover_cell)
	var dropped := 0
	if target != null and BeltSim.is_belt(target):
		dropped = BeltSim.try_insert(target, item_name, count)
	elif target != null and target.proto_type == "item-entity":
		if str(target.state.get("item", "")) == item_name:
			target.state["count"] = int(target.state.get("count", 0)) + count
			dropped = count
	elif target == null:
		if simulation != null and simulation._drop_on_ground(hover_cell, item_name, count):
			dropped = count
	if dropped <= 0:
		FactorioAudio.play_utility("cannot_build", hover_cell)
		return 0
	count -= dropped
	if count > 0:
		cursor_item["count"] = count
	else:
		cursor_item = {}
	FactorioAudio.play_utility("inventory_move", (Vector2(hover_cell) + Vector2(0.5, 0.5)))
	inventory_changed.emit()
	queue_redraw()
	return dropped


## Take one of ``item_name`` out of the hand that is holding it.
func consume_held(item_name: String) -> void:
	if creative:
		return
	if str(cursor_item.get("name", "")) == item_name:
		var left := int(cursor_item.get("count", 0)) - 1
		if left > 0:
			cursor_item["count"] = left
		else:
			cursor_item = {}
		inventory_changed.emit()
	else:
		inventory.extract(item_name, 1)


## Put everything on the cursor back into the inventory.
func return_cursor_item() -> void:
	if cursor_item.is_empty():
		return
	var held := cursor_item
	cursor_item = {}
	if not (held.has("blueprint")):
		inventory.insert(str(held["name"]), int(held["count"]))
	inventory_changed.emit()


## The `place_as_tile` definition of an item, or an empty dictionary.
##
## Landfill, foundation and the ice platform are items that change the ground
## tile.  Factorio calls this `place_as_tile`; the dump carries the result and
## the list of tiles it may replace.
static func tile_item_result(item_name: String) -> Dictionary:
	var item := Prototypes.item_proto(item_name)
	var place: Variant = item.get("place_as_tile", null)
	if place is Dictionary and not str((place as Dictionary).get("result", "")).is_empty():
		return place
	return {}


## Replace the hovered tile with a `place_as_tile` result.
func _build_tile(place: Dictionary, item_name: String) -> void:
	if world.entity_at(hover_cell) != null:
		FactorioAudio.play_utility("cannot_build", Vector2(hover_cell))
		return
	var allowed: Variant = place.get("tile_condition", [])
	if allowed is Array and not (allowed as Array).is_empty() \
			and not (allowed as Array).has(world.tile_at(hover_cell)):
		FactorioAudio.play_utility("cannot_build", Vector2(hover_cell))
		return
	var result := str(place.get("result", ""))
	if result.is_empty() or not TileAtlas.is_valid(result):
		FactorioAudio.play_utility("cannot_build", Vector2(hover_cell))
		return
	world.set_tile(hover_cell, result)
	consume_held(item_name)
	FactorioAudio.play_utility("build_small", Vector2(hover_cell))
	inventory_changed.emit()


## Green/red footprint for a tile item in the build preview.
func _draw_tile_preview(place: Dictionary) -> void:
	var allowed: Variant = place.get("tile_condition", [])
	var ok := allowed is Array and ((allowed as Array).is_empty() \
		or (allowed as Array).has(world.tile_at(hover_cell)))
	var colour := Color(0.65, 1.0, 0.7, 0.4) if ok \
		else Color(1.0, 0.35, 0.3, 0.35)
	var rect := Rect2(Vector2(hover_cell) * TILE, Vector2(TILE, TILE))
	draw_rect(rect, Color(colour.r, colour.g, colour.b, colour.a * 0.5), true)
	draw_rect(rect, Color(colour.r, colour.g, colour.b, 0.9), false, 2.0)


## Find the prototype type that ``item_name`` places.
## The carriages, which are put onto rails rather than onto the ground.
const ROLLING_STOCK := ["locomotive", "cargo-wagon", "fluid-wagon",
	"artillery-wagon"]


## The prototype name an item puts down.
static func placed_name(item_name: String, proto_type: String) -> String:
	var place_result: Variant = Prototypes.item_proto(item_name).get("place_result")
	if place_result != null:
		return str(place_result)
	if Prototypes.has(proto_type, item_name):
		return item_name
	return item_name


static func is_rolling_stock(item_name: String) -> bool:
	return item_name in ROLLING_STOCK


## Lay one rail piece, preferring a curve that actually joins a neighbouring
## rail.  R still rotates the preferred straight/axis; the curve choice is
## automatic because Factorio's rail planner also joins tracks rather than
## asking for a separate curve item.
func _place_rail_at(cell: Vector2i, item_name: String) -> bool:
	var best := _best_rail_candidate(cell)
	if best == null:
		return false
	if not world.place_entity(best):
		return false
	consume_held(item_name)
	if simulation != null:
		simulation.mark_power_dirty()
	_play_build_sound(best)
	built.emit(best)
	return true


## The rail piece the planner would put at ``cell`` right now.  The preview
## uses the same candidate search as the build, so R shows the real curve
## before the click instead of always drawing a straight rail.
func _best_rail_candidate(cell: Vector2i) -> Entity:
	var best: Entity = null
	var best_score := -1
	var names := ["straight-rail", "curved-rail-a", "curved-rail-b"]
	for piece_name: String in names:
		var directions := [build_direction]
		for d in [0, 4, 8, 12]:
			if not directions.has(d):
				directions.append(d)
		for d: int in directions:
			var candidate := Entity.create(piece_name, piece_name, cell, d)
			if not world.can_place_terrain(candidate) or not world.can_place(candidate):
				continue
			var score := _rail_connection_score(candidate)
			if piece_name == "straight-rail" and score == 0:
				if posmod(d, 8) != posmod(build_direction, 8):
					continue
			if score > best_score:
				best_score = score
				best = candidate
	return best

## How many rail end points of ``candidate`` meet an existing rail, with a
## bonus when the headings agree (a real join rather than two buffers).
func _rail_connection_score(candidate: Entity) -> int:
	var path := RailGeometry.path_of(candidate)
	if path.is_empty():
		return 0
	var starts := [Vector2(path["start"]), Vector2(path["end"])]
	var dirs := [int(path["start_dir"]), int(path["end_dir"])]
	var score := 0
	for other: Entity in world.entities.values():
		if not Trains.is_rail(other) or other == candidate or other.is_ghost():
			continue
		if other.origin.distance_squared_to(candidate.origin) > 36:
			continue
		var op := RailGeometry.path_of(other)
		if op.is_empty():
			continue
		var o_starts := [Vector2(op["start"]), Vector2(op["end"])]
		var o_dirs := [int(op["start_dir"]), int(op["end_dir"])]
		for i in 2:
			for j in 2:
				if starts[i].distance_to(o_starts[j]) > 0.05:
					continue
				score += 1
				# Opposite headings are the two ends facing outwards; in the
				# 16-way enum that is +8.  Same headings are a continuation.
				if int(dirs[i]) == int(o_dirs[j]) \
						or posmod(int(dirs[i]) + 8, 16) == int(o_dirs[j]):
					score += 2
				# R chooses which way the track should leave the join.  A curve
				# whose exit heading matches that choice beats the straight
				# continuation, which is how a corner becomes a curve.
				# The track leaves the connected endpoint through the other
				# end of the piece.  Use that exit heading for the R choice.
				var exit_dir := int(dirs[1 - i])
				if exit_dir == posmod(build_direction, 16):
					score += 4
	return score


## Put a carriage on the track under the cursor.
##
## Pointing at a train already on the rails adds the carriage to it, which is
## how a rake is assembled; pointing at bare track starts a new train there.
func place_rolling_stock(item_name: String, direction: int) -> bool:
	var guardrail := world.entity_at(hover_cell)
	if not Trains.is_rail(guardrail):
		return false
	if simulation == null or simulation.trains == null:
		return false
	# The build cursor's default direction is north (0), which is not a
	# direction a vertical rail can be entered from.  Use the rail's own
	# entry heading when the held direction does not run along it.
	if not Trains.runs_along(guardrail, direction):
		var path := RailGeometry.path_of(guardrail)
		direction = int(path.get("start_dir", direction))
	var existing := simulation.trains.carriage_at(hover_cell)
	if not existing.is_empty():
		var train: Dictionary = existing["train"]
		(train["carriages"] as Array).append(item_name)
	else:
		var train := simulation.trains.add_train([item_name], guardrail, direction)
		if train.is_empty():
			return false
	_play_build_sound(guardrail)
	consume_held(item_name)
	inventory_changed.emit()
	return true


## The rail planner's item is one thing but lays several, chosen by how the
## player is turning it.
const RAIL_PIECES := ["straight-rail", "curved-rail-a", "curved-rail-b"]


## Which rail piece to lay, given what the player asked for.
##
## The item is always `rail`; what goes down depends on the turn, the same way
## Factorio picks a curve when you drag round a corner.
static func rail_piece_for(turn: int) -> String:
	return RAIL_PIECES[posmod(turn, RAIL_PIECES.size())]


static func placeable_type(item_name: String) -> String:
	# What the item says it places is the authority; the list below is only a
	# fallback for prototypes that leave place_result out.
	var place_result: Variant = Prototypes.item_proto(item_name).get("place_result")
	if place_result != null:
		var resolved := Prototypes.entity_type_of(str(place_result))
		if not resolved.is_empty():
			return resolved
	for proto_type: String in [
			"transport-belt", "underground-belt", "splitter", "inserter",
			"mining-drill", "furnace", "assembling-machine", "container",
			"logistic-container", "electric-pole", "solar-panel", "generator",
			"boiler", "pipe", "pipe-to-ground", "pump", "lab", "ammo-turret",
			"electric-turret", "wall", "gate", "radar", "roboport", "beacon",
			"accumulator", "reactor", "rocket-silo", "artillery-turret",
			"arithmetic-combinator", "decider-combinator", "constant-combinator",
			"programmable-speaker", "train-stop", "straight-rail", "rail-ramp",
			"curved-rail-a", "curved-rail-b", "half-diagonal-rail",
			"car", "spider-vehicle"]:
		if Prototypes.has(proto_type, item_name):
			return proto_type
	var item := Prototypes.get_p("item", item_name)
	var placed: Variant = item.get("place_result")
	if placed != null:
		var result := str(placed)
		for proto_type: String in Prototypes.type_names():
			if Prototypes.has(proto_type, result):
				return proto_type
	return ""


## The report of a shot, taken from the gun's own attack parameters so a
## submachine gun and a shotgun do not sound alike.
func _play_shot_sound(gun_name: String, ammo_name: String) -> void:
	var where := character.position if character != null else hover_cell
	var from_gun: Variant = null
	var gun := Prototypes.get_p("gun", gun_name)
	if not gun.is_empty():
		from_gun = (gun.get("attack_parameters", {}) as Dictionary).get("sound")
	if FactorioAudio.has_sound(from_gun):
		FactorioAudio.play_at(from_gun, where)
		return
	# Some guns leave it to the magazine.
	var ammo := Prototypes.get_p("ammo", ammo_name)
	if not ammo.is_empty():
		var from_ammo: Variant = (ammo.get("attack_parameters", {}) as Dictionary).get("sound")
		if FactorioAudio.has_sound(from_ammo):
			FactorioAudio.play_at(from_ammo, where)


## The build noise, chosen by how big the thing is — Factorio's own split
## between small, medium, large and huge.
func _play_build_sound(entity: Entity, at := Vector2.INF) -> void:
	var where: Vector2 = at if at != Vector2.INF else Vector2(entity.center())
	var footprint := maxi(entity.size.x, entity.size.y)
	var name := "build_small"
	if footprint >= 5:
		name = "build_huge"
	elif footprint >= 3:
		name = "build_large"
	elif footprint >= 2:
		name = "build_medium"
	FactorioAudio.play_utility(name, where)


## The swing that plays while the engineer is mining, and what it is mining.
func _mining_sound_name() -> String:
	if character == null or character.mining_target.is_empty():
		return "axe_mining_stone"
	var target: Dictionary = character.mining_target
	if str(target.get("kind", "")) == "resource":
		var ore := world.ore_at(target.get("cell", Vector2i.ZERO))
		var proto := Prototypes.get_p("resource", str(ore.get("name", "")))
		# Factorio splits the swing by what the resource sounds like.
		var category := str(proto.get("mining_sound", ""))
		if not category.is_empty():
			return category if FactorioAudio.has_sound(
				FactorioAudio.utility_sound(category)) else "axe_mining_ore"
		return "axe_mining_ore"
	return "axe_mining_stone"


func _tick_mining_sound() -> void:
	if character == null or character.mining_target.is_empty():
		_mining_swing = 0
		return
	if _mining_swing > 0:
		_mining_swing -= 1
		return
	_mining_swing = 16
	FactorioAudio.play_utility(_mining_sound_name(), character.position)


## Whether the cursor is carrying a blueprint rather than an item.
func held_blueprint() -> Dictionary:
	return Blueprints.from_item(cursor_item)


## Ctrl+left on a machine: take what it has finished, and nothing else.
##
## Factorio empties the *output* and leaves the fuel and the ingredients where
## they are — a furnace gives up its plates and keeps its coal and its ore.
func take_all_from(entity: Entity) -> void:
	var taken := take_all_output(entity)
	if taken <= 0:
		FactorioAudio.play_utility("cannot_build", entity.center())
		return
	FactorioAudio.play_utility("inventory_move", entity.center())
	inventory_changed.emit()
	picked_up.emit(taken)


## Whether the current hand can start a left-drag building line.  Belts and
## normal machines qualify; trains, blueprints and rails keep their own
## placement rules.
func _can_start_drag() -> bool:
	if not hover_valid or input_blocked or wire_colour != "":
		return false
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_SHIFT):
		return false
	var item_name := held_item()
	if item_name.is_empty() or held_count(item_name) <= 0:
		return false
	if not held_blueprint().is_empty() or is_rolling_stock(item_name):
		return false
	var proto_type := placeable_type(item_name)
	if proto_type.is_empty() or proto_type in [
			"straight-rail", "curved-rail-a", "curved-rail-b"]:
		return false
	# Starting over an existing object must keep the click's normal meaning
	# (open a machine, pick up an item, etc.).
	if world.entity_at(hover_cell) != null:
		return false
	return true


## Fill every cell between the last drag cell and the cursor, so a fast mouse
## stroke does not leave gaps in a belt or a wall.
func _tick_drag_building() -> void:
	if not _drag_building:
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_drag_building = false
		return
	if _drag_item.is_empty() or _drag_item != held_item():
		_drag_building = false
		return
	if hover_cell == _drag_last:
		return
	var from := _drag_last
	var to := hover_cell
	var delta := to - from
	var steps := maxi(absi(delta.x), absi(delta.y))
	if steps > 64:
		steps = 64
	var previous := from
	for i in range(1, steps + 1):
		var cell := Vector2i(
			from.x + int(round(float(delta.x) * float(i) / float(steps))),
			from.y + int(round(float(delta.y) * float(i) / float(steps))))
		if not _in_reach(cell):
			break
		if world.entity_at(cell) == null:
			if _drag_item in ["transport-belt", "underground-belt", "splitter"]:
				var step := cell - previous
				if step != Vector2i.ZERO:
					build_direction = Character._direction_from_vector(Vector2(step))
			hover_cell = cell
			hover_valid = true
			build_at_cursor()
			if held_count(_drag_item) <= 0:
				_drag_building = false
				break
		previous = cell
	_drag_last = to
	hover_cell = to
	hover_valid = _in_reach(to)


func build_at_cursor() -> void:
	if not hover_valid:
		return
	# Shift puts the plan down rather than the machine, which is how a
	# blueprint is laid out by hand.
	if Input.is_key_pressed(KEY_SHIFT):
		place_ghost_at_cursor()
		return
	# A blueprint on the cursor pastes instead of building.
	var blueprint := held_blueprint()
	if not blueprint.is_empty():
		place_blueprint_at(hover_cell)
		return
	# With a carriage in hand the click couples it to the train; with an empty
	# hand the same click opens the train.  The order matters: checking for a
	# carriage first would make it impossible to build a rake.
	var held := held_item()
	if simulation != null and simulation.trains != null \
			and not is_rolling_stock(held):
		var carriage := simulation.trains.carriage_at(hover_cell)
		if not carriage.is_empty():
			train_activated.emit(carriage["train"])
			return
	if is_rolling_stock(held):
		if place_rolling_stock(held, build_direction):
			inventory_changed.emit()
		return
	var existing := world.entity_at(hover_cell)
	if existing != null:
		if existing.proto_type == "item-entity":
			_pick_up_ground_item(existing)
			return
		# A ghost under the cursor is a request to build it for real.
		if existing.is_ghost():
			revive_ghost_at(existing)
			return
		# Belts are floor furniture: clicking one must not open a machine
		# window.  Mining is still the right mouse button.
		if BeltSim.is_belt(existing):
			return
		entity_activated.emit(existing)
		return
	var item_name := held_item()
	if item_name.is_empty():
		return
	# Landfill and the other `place_as_tile` items change the ground rather
	# than standing an entity on it.
	var tile_place := tile_item_result(item_name)
	if not tile_place.is_empty():
		if held_count(item_name) <= 0:
			FactorioAudio.play_utility("cannot_build", Vector2(hover_cell))
			return
		_build_tile(tile_place, item_name)
		return
	# Q (and a quickbar slot) can hold an item the player does not own.  It is
	# still useful: the click lays down its ghost, exactly like Factorio.
	if held_count(item_name) <= 0:
		place_ghost_at_cursor()
		return
	var proto_type := placeable_type(item_name)
	if proto_type.is_empty():
		return
	if proto_type in ["straight-rail", "curved-rail-a", "curved-rail-b"]:
		_place_rail_at(hover_cell, item_name)
		return
	# The entity a thing places is not always named after the thing: the rail
	# planner's item is "rail" but the rail is "straight-rail".
	var entity := Entity.create(proto_type,
		placed_name(item_name, proto_type), hover_cell, build_direction)
	if not entity.is_valid():
		return
	if entity.proto_type == "offshore-pump" and not world.can_place_terrain(entity):
		# Pick the first shore-facing rotation automatically.  R still chooses
		# a different side when more than one shore touches the tile.
		for turn in [4, 8, 12]:
			entity.direction = posmod(build_direction + turn, 16)
			if world.can_place_terrain(entity):
				break
	if not world.can_place_terrain(entity):
		FactorioAudio.play_utility("cannot_build", entity.center())
		return
	if not world.place_entity(entity):
		FactorioAudio.play_utility("cannot_build", entity.center())
		return
	consume_held(item_name)
	simulation.mark_power_dirty()
	_play_build_sound(entity)
	built.emit(entity)


## Empty a machine's output into the inventory.
##
## Only the output: a furnace gives up its plates and keeps its coal and its
## ore, which is what Factorio's ctrl-click does.  Returns how many items
## changed hands.
func take_all_output(entity: Entity) -> int:
	var output := InventoryLayout.get_inventory(entity, InventoryLayout.OUTPUT)
	if output == null:
		return 0
	var moved := 0
	for slot: Variant in output.slots.duplicate():
		if slot == null:
			continue
		var name := str((slot as Dictionary)["name"])
		var count := int((slot as Dictionary)["count"])
		var accepted := int(count - inventory.insert(name, count))
		if accepted <= 0:
			continue
		output.extract(name, accepted)
		moved += accepted
	return moved


## One end of a wire, then the other.
##
## The first click takes hold of a device; the second joins it.  Clicking the
## same device twice wires it to itself, which is how a counter is built.
func _wire_click() -> void:
	var target := world.entity_at(hover_cell)
	if target == null or target.is_ghost():
		_wire_from = null
		return
	if _wire_from == null:
		if simulation != null and simulation.circuits != null \
				and not simulation.circuits.can_wire(target):
			return
		_wire_from = target
		FactorioAudio.play_utility("gui_click", Vector2(target.center()))
		return
	if simulation != null and simulation.circuits != null:
		var placed := simulation.circuits.add_wire(_wire_from, target, wire_colour)
		FactorioAudio.play_utility(
			"gui_click" if placed else "cannot_build",
			Vector2(target.center()))
	_wire_from = null
	queue_redraw()


## Put a single ghost at the cursor, without spending anything.
func place_ghost_at_cursor() -> void:
	var item_name := held_item()
	if item_name.is_empty():
		return
	# A ghost over something already built would be pointless.
	if world.entity_at(hover_cell) != null:
		return
	if is_rolling_stock(item_name):
		return
	var proto_type := placeable_type(item_name)
	if proto_type.is_empty():
		return
	var entity: Entity
	if proto_type in ["straight-rail", "curved-rail-a", "curved-rail-b"]:
		entity = _best_rail_candidate(hover_cell)
	else:
		entity = Entity.create(proto_type, placed_name(item_name, proto_type),
			hover_cell, build_direction)
	if entity == null or not entity.is_valid():
		return
	if not world.place_ghost(entity):
		return
	FactorioAudio.play_utility("build_ghost_upgrade", entity.center())
	simulation.mark_power_dirty()
	blueprint_placed.emit({"built": [], "ghosts": [hover_cell], "blocked": []})


## Put a blueprint down, buying what the inventory can cover and leaving the
## rest as ghosts — the same bargain Factorio offers.
func place_blueprint_at(origin: Vector2i) -> void:
	var blueprint := held_blueprint()
	if blueprint.is_empty():
		return
	var result := Blueprints.place(world, blueprint, origin, inventory)
	simulation.mark_power_dirty()
	simulation.fluids.mark_dirty()
	simulation.logistics.mark_dirty()
	blueprint_placed.emit(result)
	inventory_changed.emit()
	if (result["ghosts"] as Array).is_empty():
		# Placed in full, so the blueprint goes back to being an item.
		pass


## Build a ghost the player is standing at, if they have the materials.
func revive_ghost_at(ghost: Entity) -> void:
	var proto_type := str(ghost.state.get("ghost_of", ghost.proto_type))
	# Check the ground before taking the materials: reviving a drill ghost on
	# bare grass must not eat the player's iron and then put the ghost back.
	var probe := Entity.create(proto_type, ghost.name, ghost.origin, ghost.direction)
	if not world.can_place_terrain(probe):
		FactorioAudio.play_utility("cannot_build", ghost.center())
		return
	var costs := Blueprints.costs_of(proto_type, ghost.name)
	if not costs.is_empty():
		if not inventory.has_at_least(costs):
			return
		for cost: Dictionary in costs:
			inventory.extract(str(cost["name"]), int(cost["amount"]))
	var real := world.revive_ghost(ghost)
	if real != null:
		if not world.can_place_terrain(real):
			# Put the plan back and refund the materials.
			for cost: Dictionary in costs:
				inventory.insert(str(cost["name"]), int(cost["amount"]))
			world.remove_entity(real)
			world.place_ghost(ghost)
			return
		simulation.mark_power_dirty()
		simulation.fluids.mark_dirty()
		simulation.logistics.mark_dirty()
		built.emit(real)
		inventory_changed.emit()


## Start, extend and finish a Ctrl-drag copy.
func copy_drag(cell: Vector2i, pressed: bool) -> void:
	if pressed:
		if not _copy_dragging:
			_copy_anchor = cell
			_copy_dragging = true
		_copy_rect = Rect2i(
			Vector2i(mini(_copy_anchor.x, cell.x), mini(_copy_anchor.y, cell.y)),
			Vector2i(absi(cell.x - _copy_anchor.x) + 1,
				absi(cell.y - _copy_anchor.y) + 1))
		return
	if not _copy_dragging:
		return
	_copy_dragging = false
	if _copy_rect.size.x < 1 or _copy_rect.size.y < 1:
		return
	var blueprint := Blueprints.capture(world, _copy_rect)
	print("copied %d entities in a %dx%d blueprint" % [
		(blueprint["entities"] as Array).size(), _copy_rect.size.x,
		_copy_rect.size.y])
	# The blueprint goes onto the cursor, ready to paste, exactly as Factorio
	# hands you the item.
	cursor_item = {"name": Blueprints.ITEM, "count": 1, "blueprint": blueprint}
	inventory_changed.emit()


func copy_rect() -> Rect2i:
	return _copy_rect


func copy_dragging() -> bool:
	return _copy_dragging


func mine_at_cursor() -> void:
	if not hover_valid:
		return
	var entity := world.entity_at(hover_cell)
	if entity != null:
		if entity.is_ghost():
			world.remove_entity(entity)
			FactorioAudio.play_utility("deconstruct_small", entity.center())
			inventory_changed.emit()
			return
		_mine_entity(entity)
		return
	var ore := world.ore_at(hover_cell)
	var ore_name: String = ore["name"]
	if ore_name.is_empty() or float(ore["amount"]) <= 0.0:
		return
	var taken := int(world.mine_ore(hover_cell, 1.0))
	if taken > 0:
		inventory.insert(ore_name, taken)
		mined.emit(ore_name, taken)


func _mine_entity(entity: Entity) -> void:
	if entity.proto_type == "item-entity":
		_pick_up_ground_item(entity)
		return
	if GameWorld.is_decorative(entity):
		_mine_decorative(entity)
		return
	# Anything an entity holds spills into the player's inventory.
	var inventories: Dictionary = entity.state.get("inventories", {})
	for key: String in inventories:
		var inv: Variant = inventories[key]
		if not (inv is Inventory):
			continue
		for slot: Variant in (inv as Inventory).slots:
			if slot == null:
				continue
			inventory.insert(str(slot["name"]), int(slot["count"]))
			slot["count"] = 0
		(inv as Inventory).clear()
	if BeltSim.is_belt(entity):
		for item: Dictionary in BeltSim.items_of(entity):
			inventory.insert(str(item["name"]), int(item["count"]))
		BeltSim.items_of(entity).clear()
	inventory.insert(entity.name, 1)
	world.remove_entity(entity)
	simulation.mark_power_dirty()


## Q: put the item under the cursor into the hand, ready to place.
##
## It is moved out of the inventory (or off the ground), so the hand is a real
## transfer rather than a copy.  If the player owns none, the hand still holds
## the name with count 0; the next click lays down a ghost.
## Trees give wood, rocks give stone (and occasionally coal), using the
## prototype's own ``minable`` block.
func _mine_decorative(entity: Entity) -> void:
	var minable: Variant = entity.prototype().get("minable", {})
	if not (minable is Dictionary):
		minable = {}
	var results: Array = []
	var raw_results: Variant = (minable as Dictionary).get("results", [])
	if raw_results is Array:
		results = raw_results
	if results.is_empty() and (minable as Dictionary).has("result"):
		results = [{"type": "item", "name": str(minable["result"]),
			"amount": int((minable as Dictionary).get("count", 1))}]
	var total := 0
	for result: Variant in results:
		if not (result is Dictionary):
			continue
		var dict := result as Dictionary
		if str(dict.get("type", "item")) != "item":
			continue
		var amount_min := int(dict.get("amount_min", dict.get("amount", 1)))
		var amount_max := int(dict.get("amount_max", amount_min))
		var amount := randi_range(amount_min, maxi(amount_min, amount_max))
		if amount <= 0:
			continue
		inventory.insert(str(dict.get("name", "")), amount)
		total += amount
	world.remove_entity(entity)
	inventory_changed.emit()
	if total > 0:
		picked_up.emit(total)


## Hand a creative item to the cursor without crafting it.
func creative_give(item_name: String, amount := 1) -> void:
	if item_name.is_empty():
		return
	if not cursor_item.is_empty():
		return_cursor_item()
	cursor_item = {"name": item_name, "count": maxi(1, amount)}
	inventory_changed.emit()
	queue_redraw()


func pick_from_cursor() -> void:
	var entity := world.entity_at(hover_cell)
	var item_name := ""
	var count := 0
	if entity != null:
		if entity.proto_type == "item-entity":
			item_name = str(entity.state.get("item", ""))
			count = int(entity.state.get("count", 0))
			if count > 0:
				world.remove_entity(entity)
		else:
			item_name = entity.name
			count = inventory.count_of(item_name)
			if count > 0:
				# Moving the stack, not copying it: otherwise Q on the same
				# object twice would put a fresh copy back each time.
				count = inventory.extract(item_name, count)
	else:
		item_name = str(world.ore_at(hover_cell)["name"])
		count = inventory.count_of(item_name)
		if count > 0:
			count = inventory.extract(item_name, count)
	if item_name.is_empty():
		return
	if creative and count <= 0:
		count = 1
	if count <= 0 and entity == null:
		# Ore the player has never mined: nothing useful to place.
		return
	cursor_item = {"name": item_name, "count": count}
	inventory_changed.emit()
	queue_redraw()


# --------------------------------------------------------------------------
# cursor overlay
# --------------------------------------------------------------------------

## The machine the player is holding, drawn at the cursor turned the way it
## would be built.  Factorio shows this faintly, tinted by whether it can go
## there at all, and it is the only way to see what R is doing.
func _draw_build_preview() -> void:
	var item_name := held_item()
	if item_name.is_empty() or is_rolling_stock(item_name):
		return
	var tile_place := tile_item_result(item_name)
	if not tile_place.is_empty():
		_draw_tile_preview(tile_place)
		return
	var proto_type := placeable_type(item_name)
	if proto_type.is_empty():
		return
	var entity: Entity
	if proto_type in ["straight-rail", "curved-rail-a", "curved-rail-b"]:
		entity = _best_rail_candidate(hover_cell)
	else:
		entity = Entity.create(proto_type, placed_name(item_name, proto_type),
			hover_cell, build_direction)
	if entity == null or not entity.is_valid():
		return
	var can_place: bool = world.can_place(entity) and world.can_place_terrain(entity)
	var tint := Color(1, 1, 1, 0.35)
	if held_count(item_name) <= 0:
		# Nothing to spend: the click will lay down a ghost.  Show it blue.
		tint = Color(0.45, 0.6, 1.0, 0.35)
	elif not can_place:
		# Red where it will not fit, which also previews the footprint.
		tint = Color(1.0, 0.35, 0.3, 0.35)
	else:
		tint = Color(0.65, 1.0, 0.7, 0.4)

	var data := EntityVisuals.visual(entity, 0, world)
	if data.is_empty():
		# Some things have no art to preview, so show the footprint instead.
		_draw_footprint(entity, tint)
		return
	var direction := int(data["direction"])
	var spin := float(data.get("rotation", 0.0))
	var centre := entity.center() * TILE
	var as_row := bool(data.get("is_row", false))
	var offsets: Array = data.get("offsets", [])
	var node_index := 0
	for graphics: Variant in data["nodes"]:
		var tag := "preview/%s/d%d#%d" % [entity.name,
			posmod(entity.direction, 16), node_index]
		var shift := Vector2.ZERO
		if node_index < offsets.size():
			shift = Vector2(offsets[node_index]) * TILE
		node_index += 1
		var variation := EntityVisuals.variation_for(entity,
			_variation_count(graphics))
		var layers: Array = SpriteCache.layers_row(graphics, direction, 0,
			variation, tag) if as_row else SpriteCache.layers(graphics, direction,
			0, variation, tag)
		for layer: SpriteSource.Layer in layers:
			var dest := Rect2(centre + shift + layer.offset - layer.size * 0.5,
				layer.size)
			if layer.texture == null:
				continue
			var colour := Color(tint.r, tint.g, tint.b,
				tint.a * layer.modulate.a)
			# The layer says where it comes from in `src_rect`, which is what
			# the renderer reads too; `region` does not exist and asking for it
			# crashed the preview outright.
			var turned := spin + layer.rotation
			if not is_zero_approx(turned):
				draw_set_transform(dest.get_center(), turned, Vector2.ONE)
				dest = Rect2(-dest.size * 0.5, dest.size)
			if layer.src_rect.size.x > 0.0:
				draw_texture_rect_region(layer.texture, dest, layer.src_rect,
					colour)
			else:
				draw_texture_rect(layer.texture, dest, false, colour)
			if not is_zero_approx(turned):
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## How many random variations a graphic offers, which the renderer also reads.
static func _variation_count(graphics: Variant) -> int:
	if graphics is Dictionary:
		if graphics.has("variation_count"):
			return maxi(1, int(graphics["variation_count"]))
		var sheets: Variant = graphics.get("sheets")
		if sheets is Array and not (sheets as Array).is_empty():
			var first: Variant = (sheets as Array)[0]
			if first is Dictionary and (first as Dictionary).has("variation_count"):
				return maxi(1, int((first as Dictionary)["variation_count"]))
	return 1


## Turn the placed entity under the cursor.  Returns false when there is
## nothing rotatable there, so the caller can rotate the build direction.
const ROTATABLE_TYPES := [
	"transport-belt", "underground-belt", "splitter", "inserter",
	"mining-drill", "furnace", "assembling-machine", "boiler", "generator",
	"offshore-pump", "pump", "storage-tank", "pipe-to-ground",
	"ammo-turret", "electric-turret", "fluid-turret", "artillery-turret",
	"gate", "rocket-silo", "lab", "beacon", "radar", "roboport", "train-stop",
]
func _rotate_entity_under_cursor() -> bool:
	var entity := world.entity_at(hover_cell)
	if entity == null or entity.is_ghost():
		return false
	if not ROTATABLE_TYPES.has(entity.proto_type):
		return false
	if not world.rotate_entity(entity, posmod(entity.direction + 4, 16)):
		FactorioAudio.play_utility("cannot_build", entity.center())
		return true
	if simulation != null:
		simulation.mark_power_dirty()
		if simulation.fluids != null:
			simulation.fluids.mark_dirty()
		if simulation.logistics != null:
			simulation.logistics.mark_dirty()
	FactorioAudio.play_utility("gui_click", entity.center())
	return true


## Hovering an inserter shows where it takes from and what it drops into.
##
## Factorio draws the same two guides: a thin line to the pickup tile and an
## arrow into the machine it feeds.  Without them a rotated inserter is very
## hard to read, especially once the base is crowded.
func _draw_inserter_guides() -> void:
	if simulation == null:
		return
	var entity := world.entity_at(hover_cell)
	if entity == null or entity.proto_type != "inserter" or entity.is_ghost():
		return
	var proto := entity.prototype()
	if proto.is_empty():
		return
	var centre := entity.center() * TILE
	var pickup_cell := simulation._inserter_cell(entity, proto, "pickup_position")
	var insert_cell := simulation._inserter_cell(entity, proto, "insert_position")
	var pickup := (Vector2(pickup_cell) + Vector2(0.5, 0.5)) * TILE
	var drop := (Vector2(insert_cell) + Vector2(0.5, 0.5)) * TILE

	var pickup_colour := Color(0.35, 0.75, 1.0, 0.9)
	var drop_colour := Color(1.0, 0.68, 0.18, 0.95)
	# The pickup side: a short bar and a line back to the pivot.
	draw_line(centre, pickup, pickup_colour, 2.0)
	draw_rect(Rect2(pickup - Vector2(3, 3), Vector2(6, 6)), pickup_colour, true)
	draw_rect(Rect2(pickup - Vector2(TILE, TILE) * 0.5, Vector2(TILE, TILE)),
		pickup_colour, false, 1.5)
	# The drop side: an arrow from the pivot to the target tile.
	draw_line(centre, drop, drop_colour, 2.5)
	var direction := (drop - centre).normalized()
	var side := Vector2(-direction.y, direction.x)
	var tip := drop
	var back := tip - direction * 10.0
	draw_colored_polygon(PackedVector2Array([
		tip, back + side * 5.5, back - side * 5.5,
	]), drop_colour)
	draw_rect(Rect2(drop - Vector2(TILE, TILE) * 0.5, Vector2(TILE, TILE)),
		drop_colour, false, 1.5)


## Hovering a mining drill shows which side its output chute faces, so R has
## a visible effect even when the belt is not directly in front of it.
func _draw_drill_output() -> void:
	if simulation == null:
		return
	var entity := world.entity_at(hover_cell)
	if entity == null or entity.is_ghost() or entity.proto_type != "mining-drill":
		return
	var proto := entity.prototype()
	if proto.is_empty():
		return
	var target_cell := simulation._drill_output_cell(entity, proto)
	var centre := entity.center() * TILE
	var target := (Vector2(target_cell) + Vector2(0.5, 0.5)) * TILE
	var colour := Color(1.0, 0.82, 0.25, 0.9)
	draw_line(centre, target, colour, 2.0)
	var direction := (target - centre).normalized()
	var side := Vector2(-direction.y, direction.x)
	draw_colored_polygon(PackedVector2Array([
		target, target - direction * 10.0 + side * 5.0,
		target - direction * 10.0 - side * 5.0,
	]), colour)
	draw_rect(Rect2(Vector2(target_cell) * TILE, Vector2(TILE, TILE)),
		colour, false, 2.0)


## Hovering an electric pole shows what it powers and how far its copper wire
## can reach.  The orange circle is the wire range used by PowerNetwork; the
## green square is the supply area.
func _draw_pole_radius() -> void:
	var entity := world.entity_at(hover_cell)
	if entity == null or entity.proto_type != "electric-pole":
		return
	var proto := entity.prototype()
	if proto.is_empty():
		return
	var centre := entity.center() * TILE
	var wire_range := float(proto.get("maximum_wire_distance", 7.5)) * TILE
	var supply := float(proto.get("supply_area_distance", 2.5))
	var half := (supply + 0.5) * TILE
	var supply_rect := Rect2(centre - Vector2(half, half), Vector2(half * 2.0, half * 2.0))
	draw_rect(supply_rect, Color(0.4, 0.9, 0.5, 0.055), true)
	draw_rect(supply_rect, Color(0.4, 0.9, 0.5, 0.65), false, 2.0)
	draw_arc(centre, wire_range, 0.0, TAU, 128,
		Color(0.95, 0.62, 0.2, 0.85), 2.0, true)


## While a pole is in hand, show the wires it would connect to.  The curve
## uses the same sagging helper as the real network wires, so it is obvious
## whether the new pole reaches before it is placed.
func _draw_pole_preview_wires() -> void:
	if not hover_valid or input_blocked or not wire_colour.is_empty():
		return
	var item_name := held_item()
	if item_name.is_empty() or placeable_type(item_name) != "electric-pole":
		return
	var preview := Entity.create("electric-pole", placed_name(item_name, "electric-pole"),
		hover_cell, build_direction)
	if preview == null or not preview.is_valid():
		return
	var can_place := world.can_place(preview) and world.can_place_terrain(preview)
	# Green preview wires stand out from the orange installed network and make
	# a reachable pole obvious before it is placed.
	var colour := Color(0.4, 1.0, 0.55, 0.85)
	if held_count(item_name) <= 0:
		colour = Color(0.5, 0.65, 1.0, 0.7)
	elif not can_place:
		colour = Color(1.0, 0.35, 0.3, 0.8)
	var own_reach := float(preview.prototype().get("maximum_wire_distance", 7.5))
	var anchor := PowerNetwork.wire_anchor(preview)
	for pole: Entity in world.entities_of_type("electric-pole"):
		if pole.is_ghost():
			continue
		var reach := maxf(own_reach, float(pole.prototype().get(
			"maximum_wire_distance", 7.5)))
		if preview.center().distance_to(pole.center()) > reach + 0.01:
			continue
		var points := PowerNetwork.wire_curve(anchor, PowerNetwork.wire_anchor(pole))
		draw_polyline(points, colour, 2.0, true)


## A plain rectangle where a thing without art would stand.
func _draw_footprint(entity: Entity, colour: Color) -> void:
	var rect := Rect2(Vector2(entity.origin) * TILE,
		Vector2(entity.size) * TILE)
	draw_rect(rect, Color(colour.r, colour.g, colour.b, colour.a * 0.5), true)
	draw_rect(rect, Color(colour.r, colour.g, colour.b, 0.9), false, 2.0)


func _draw() -> void:
	if not hover_valid:
		return
	# While a copy is being dragged the selection is what matters.
	if _copy_dragging:
		var selection := Rect2(Vector2(_copy_rect.position) * TILE,
			Vector2(_copy_rect.size) * TILE)
		draw_rect(selection, Color(0.4, 0.75, 1.0, 0.9), false, 2.0)
		draw_rect(selection, Color(0.4, 0.75, 1.0, 0.12), true)
		return
	# A wire being pulled follows the cursor, so the far end is visible.
	if not wire_colour.is_empty():
		if _wire_from != null and world.entities.has(_wire_from.origin):
			var colour := Color(0.9, 0.25, 0.25) \
				if wire_colour == CircuitNetwork.RED else Color(0.3, 0.85, 0.3)
			draw_line(_wire_from.center() * TILE,
				Vector2(hover_cell) * TILE + Vector2(TILE, TILE) * 0.5,
				colour, 2.0)
	_draw_build_preview()
	_draw_pole_preview_wires()
	_draw_inserter_guides()
	_draw_drill_output()
	_draw_pole_radius()
	var rect := Rect2(Vector2(hover_cell) * TILE, Vector2(TILE, TILE))
	var colour := Color(0.4, 1.0, 0.5, 0.55)
	var mineable := world.entity_at(hover_cell) != null \
		or not str(world.ore_at(hover_cell)["name"]).is_empty()
	if mineable:
		colour = Color(1.0, 0.6, 0.3, 0.55)
	draw_rect(rect, colour, false, 2.0)
	draw_rect(rect, Color(colour.r, colour.g, colour.b, 0.12), true)

	# Hand-mining progress, drawn as a bar under the target like Factorio's.
	var progress := mining_progress()
	if progress >= 0.0:
		var bar := Rect2(Vector2(hover_cell) * TILE + Vector2(2, TILE - 7),
			Vector2(TILE - 4, 4))
		draw_rect(bar, Color(0, 0, 0, 0.6), true)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(progress, 0.0, 1.0),
			bar.size.y)), Color(0.35, 0.85, 0.35, 0.95), true)


# --------------------------------------------------------------------------
# quickbar UI
# --------------------------------------------------------------------------

func _build_quickbar_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "QuickbarLayer"
	layer.layer = 2
	add_child(layer)
	_hotbar_ui = GridContainer.new()
	_hotbar_ui.name = "Quickbar"
	_hotbar_ui.columns = QUICKBAR_COLUMNS
	_hotbar_ui.add_theme_constant_override("h_separation", QUICKBAR_GAP)
	_hotbar_ui.add_theme_constant_override("v_separation", QUICKBAR_GAP)
	layer.add_child(_hotbar_ui)

	for i in quickbar.size():
		var frame := PanelContainer.new()
		frame.clip_contents = true
		# The slot is itself clickable: with an item on the cursor a click
		# assigns it here, with an empty cursor it just selects the slot.
		frame.mouse_filter = Control.MOUSE_FILTER_STOP
		frame.custom_minimum_size = Vector2(QUICKBAR_SLOT, QUICKBAR_SLOT)
		frame.gui_input.connect(_on_quickbar_slot_input.bind(i))
		var stack := Control.new()
		stack.custom_minimum_size = Vector2(QUICKBAR_SLOT, QUICKBAR_SLOT)
		stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(stack)

		var icon := TextureRect.new()
		# Without EXPAND_IGNORE_SIZE the 64-pixel atlas icon forces a minimum
		# size larger than the 52-pixel slot, and the icon spills out of it.
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 4
		icon.offset_top = 4
		icon.offset_right = -4
		icon.offset_bottom = -4
		stack.add_child(icon)

		# How many of this item the player is carrying, like Factorio's bar.
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
		stack.add_child(count)

		_hotbar_ui.add_child(frame)
		_slot_icons.append({"frame": frame, "icon": icon, "count": count})

	_build_wire_bar(layer)
	item_picker = ItemPicker.new(self)
	layer.add_child(item_picker)
	item_picker.item_chosen.connect(_on_item_picker_chosen)
	_update_quickbar_ui()


## The two wire tools beside the quickbar.  Taking a wire is an explicit
## choice now: it used to be a hidden keyboard mode, and a forgotten mode made
## every click try to string a wire instead of opening a machine.
func _build_wire_bar(layer: CanvasLayer) -> void:
	_wire_bar = HBoxContainer.new()
	_wire_bar.name = "WireBar"
	_wire_bar.add_theme_constant_override("separation", 4)
	layer.add_child(_wire_bar)
	for colour: String in [CircuitNetwork.RED, CircuitNetwork.GREEN]:
		var button := Button.new()
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(40, 40)
		button.tooltip_text = "%s wire — click to take, click again (or right click) to put away" % colour.capitalize()
		var icon := TextureRect.new()
		icon.texture = FactorioAssets.prototype_icon(Prototypes.item_proto(
			"%s-wire" % colour), 64)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 5
		icon.offset_top = 5
		icon.offset_right = -5
		icon.offset_bottom = -5
		button.add_child(icon)
		button.pressed.connect(_toggle_wire_tool.bind(colour))
		button.gui_input.connect(_on_wire_button_input.bind(colour))
		_wire_bar.add_child(button)
		_wire_buttons[colour] = button
	_update_wire_buttons()


func _on_wire_button_input(event: InputEvent, colour: String) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
		cancel_wire()
		get_viewport().set_input_as_handled()


## Take a wire, or put the same one away.
func _toggle_wire_tool(colour: String) -> void:
	if wire_colour == colour:
		cancel_wire()
		return
	wire_colour = colour
	_wire_from = null
	emit_signal("wiring_changed", wire_colour)
	_update_wire_buttons()
	queue_redraw()


## Put the wire tool away.  Called by the buttons, by right click in the world
## and by Escape.
func cancel_wire() -> void:
	if wire_colour.is_empty():
		return
	wire_colour = ""
	_wire_from = null
	emit_signal("wiring_changed", wire_colour)
	_update_wire_buttons()
	queue_redraw()


func _update_wire_buttons() -> void:
	for colour: String in _wire_buttons:
		var button: Button = _wire_buttons[colour]
		var active := wire_colour == colour
		button.set_pressed_no_signal(active)
		button.modulate = Color(1, 1, 1, 1)
		for state: String in ["default", "hovered", "pressed"]:
			var key: String = {"default": "normal", "hovered": "hover",
				"pressed": "pressed"}[state]
			if active:
				# A toggle uses the "pressed" box while it is held down, and the
				# Factorio button art is a texture, so an explicit green flat
				# box is the only highlight that reads as "wire in hand".
				var lit := StyleBoxFlat.new()
				lit.bg_color = Color(0.26, 0.52, 0.22, 0.95)
				lit.border_color = Color(0.55, 0.9, 0.4, 1.0)
				lit.set_border_width_all(2)
				lit.set_corner_radius_all(3)
				button.add_theme_stylebox_override(key, lit)
				continue
			var box := FactorioStyle.stylebox("button", state)
			if box != null:
				button.add_theme_stylebox_override(key, box)


## A click on a quickbar slot.
##
## Left click selects the slot, or — when the inventory has put an item on the
## cursor — stores that item in the slot without consuming it.  Right click
## clears the slot.  This is how the bar is edited.
func _on_quickbar_slot_input(event: InputEvent, index: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if not button.pressed:
		return
	if button.button_index == MOUSE_BUTTON_LEFT:
		if not cursor_item.is_empty() and not str(cursor_item.get("name", "")).is_empty():
			quickbar[index] = str(cursor_item["name"])
			selected_slot = index
			_update_quickbar_ui()
		elif str(quickbar[index]).is_empty():
			selected_slot = index
			_update_quickbar_ui()
			if item_picker != null:
				item_picker.open_for(index)
		else:
			selected_slot = index
			_update_quickbar_ui()
		# Player is a Node2D rather than a Control, so this marks the viewport
		# event handled explicitly instead of calling Control.accept_event().
		get_viewport().set_input_as_handled()
	elif button.button_index == MOUSE_BUTTON_RIGHT:
		quickbar[index] = ""
		_update_quickbar_ui()
		get_viewport().set_input_as_handled()
	elif button.button_index == MOUSE_BUTTON_MIDDLE:
		# Middle-click the shortcut bar to clear that shortcut; the item itself
		# stays in the inventory.
		quickbar[index] = ""
		_update_quickbar_ui()
		get_viewport().set_input_as_handled()


## Set the selected slot to ``item_name`` without touching the inventory, for
## the middle click in the inventory window.
func assign_quickbar_slot(item_name: String) -> void:
	if item_name.is_empty() or selected_slot < 0 or selected_slot >= quickbar.size():
		return
	quickbar[selected_slot] = item_name
	_update_quickbar_ui()


func _on_item_picker_chosen(item_name: String) -> void:
	if item_picker == null:
		return
	var index := item_picker.slot_index
	if index < 0 or index >= quickbar.size():
		return
	quickbar[index] = item_name
	selected_slot = index
	_update_quickbar_ui()


func refresh_quickbar() -> void:
	_update_quickbar_ui()


## Hide the quickbar while the title screen is up.
func set_hud_visible(on: bool) -> void:
	if _hotbar_ui != null:
		_hotbar_ui.visible = on
	if _wire_bar != null:
		_wire_bar.visible = on
	if item_picker != null and not on:
		item_picker.visible = false


func _update_quickbar_ui() -> void:
	for i in _slot_icons.size():
		var entry: Dictionary = _slot_icons[i]
		var icon: TextureRect = entry["icon"]
		var frame: PanelContainer = entry["frame"]
		var item_name := str(quickbar[i]) if i < quickbar.size() else ""
		icon.texture = FactorioAssets.prototype_icon(Prototypes.item_proto(item_name))
		var count_label: Label = entry["count"]
		var held := inventory.count_of(item_name) if not item_name.is_empty() else 0
		count_label.text = str(held) if held > 0 else ""
		var selected := i == selected_slot
		frame.modulate = Color(1, 1, 1, 1) if selected else Color(0.72, 0.72, 0.72, 1)
		frame.add_theme_stylebox_override("panel", _slot_style(selected))
		if item_name.is_empty():
			frame.tooltip_text = "Empty slot (Shift+%d selects the second row)" % (
				i % QUICKBAR_COLUMNS + 1)
		else:
			frame.tooltip_text = "%s — click with an item on the cursor to replace, right click to clear" % Loc.proto_name("item", item_name)


func _slot_style(selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.09, 0.75)
	style.border_color = Color(1.0, 0.85, 0.3, 0.95) if selected else Color(0.35, 0.35, 0.38, 0.9)
	style.set_border_width_all(3 if selected else 1)
	style.set_corner_radius_all(3)
	return style


## Keep the quickbar anchored to the bottom centre as the window resizes.
func reposition_quickbar(viewport_size: Vector2) -> void:
	if _hotbar_ui == null:
		return
	var extent := _hotbar_ui.get_combined_minimum_size()
	_hotbar_ui.position = Vector2((viewport_size.x - extent.x) * 0.5,
		viewport_size.y - extent.y - 12)
	if _wire_bar != null:
		var wire_size := _wire_bar.get_combined_minimum_size()
		_wire_bar.position = Vector2(
			minf(_hotbar_ui.position.x + extent.x + 8,
				viewport_size.x - wire_size.x - 8),
			viewport_size.y - wire_size.y - 12)


# --------------------------------------------------------------------------
# hand crafting
# --------------------------------------------------------------------------

## Categories the character can craft by hand, from the character prototype.
func hand_crafting_categories() -> Array:
	var character := Prototypes.get_p("character", "character")
	var categories: Variant = character.get("crafting_categories")
	if categories is Array and not categories.is_empty():
		return categories
	return ["crafting", "basic-crafting", "advanced-crafting", "smelting"]


## Character crafting speed (Factorio's is 1, so a recipe takes its listed
## time in the player's hands).
func hand_crafting_speed() -> float:
	var character := Prototypes.get_p("character", "character")
	return float(character.get("crafting_speed", 1.0))


func has_ingredients(recipe: Dictionary) -> bool:
	for ingredient: Dictionary in Prototypes.recipe_ingredients(recipe):
		if inventory.count_of(str(ingredient["name"])) < int(ingredient["amount"]):
			return false
	return true


## Snapshot of every item in the character inventory, used by the recursive
## planner without touching the real inventory until a task actually starts.
func _inventory_counts() -> Dictionary:
	var counts: Dictionary = {}
	for slot: Variant in inventory.slots:
		if slot == null:
			continue
		var name := str(slot["name"])
		counts[name] = int(counts.get(name, 0)) + int(slot["count"])
	return counts


## How many times this recipe could be crafted right now, including all
## recursively craftable ingredients.  This is what Shift/right-click use.
func craftable_count(recipe: Dictionary) -> int:
	var recipe_name := str(recipe.get("name", ""))
	if recipe_name.is_empty() or not _recipe_is_hand_available(recipe_name):
		return 0
	var recipe_proto := Prototypes.get_p("recipe", recipe_name)
	if Prototypes.recipe_ingredients(recipe_proto).is_empty():
		return 0
	var virtual := _inventory_counts()
	var made := 0
	while made < MAX_PLANNED_CRAFTS:
		var tasks: Array = []
		if not _plan_recipe(recipe_name, 1, virtual, tasks, {}):
			break
		made += 1
	return made


func can_hand_craft(recipe_name: String) -> bool:
	if not _recipe_is_hand_available(recipe_name):
		return false
	if Prototypes.recipe_ingredients(
			Prototypes.get_p("recipe", recipe_name)).is_empty():
		return false
	var virtual := _inventory_counts()
	var tasks: Array = []
	return _plan_recipe(recipe_name, 1, virtual, tasks, {})


func _recipe_is_hand_available(recipe_name: String) -> bool:
	var recipe := Prototypes.get_p("recipe", recipe_name)
	if recipe.is_empty():
		return false
	if research != null and not research.is_recipe_unlocked(recipe_name):
		return false
	return hand_crafting_categories().has(str(recipe.get("category", "crafting")))


## Queue up to ``count`` crafts.  Missing subcomponents are planned as their
## own tasks before the parent task, so a transport belt can consume a gear
## wheel crafted from the player's iron plates.  Ingredients are consumed when
## each task starts (and its child tasks have already produced their outputs).
## Returns how many top-level crafts were queued.
func craft(recipe_name: String, count := 1) -> int:
	if count <= 0 or not _recipe_is_hand_available(recipe_name):
		return 0
	if Prototypes.recipe_ingredients(
			Prototypes.get_p("recipe", recipe_name)).is_empty():
		return 0
	var virtual := _inventory_counts()
	var tasks: Array = []
	var made := 0
	for _index in mini(count, MAX_PLANNED_CRAFTS):
		var batch: Array = []
		if not _plan_recipe(recipe_name, 1, virtual, batch, {}):
			break
		tasks.append_array(batch)
		made += 1
	if made > 0:
		craft_queue.append_array(tasks)
		inventory_changed.emit()
	return made


## Build the recipe graph once.  Recipes are not all hand-craftable in every
## context, so the final choice is filtered in `_recipe_for_item()`.
func _build_product_index() -> void:
	if not _product_recipes.is_empty():
		return
	for recipe_name: String in Prototypes.names("recipe"):
		var recipe := Prototypes.get_p("recipe", recipe_name)
		for product: Dictionary in Prototypes.recipe_products(recipe):
			if str(product.get("type", "item")) != "item":
				continue
			var name := str(product.get("name", ""))
			if name.is_empty():
				continue
			if not _product_recipes.has(name):
				_product_recipes[name] = []
			(_product_recipes[name] as Array).append(recipe_name)


## A hand-craftable recipe that makes ``item_name``, if one is unlocked.
func _recipe_for_item(item_name: String, visiting: Dictionary) -> String:
	_build_product_index()
	var candidates: Array = _product_recipes.get(item_name, [])
	for recipe_name: String in candidates:
		if visiting.has(recipe_name):
			continue
		if _recipe_is_hand_available(recipe_name):
			var recipe := Prototypes.get_p("recipe", recipe_name)
			if _product_amount(recipe, item_name) > 0:
				return recipe_name
	return ""


static func _product_amount(recipe: Dictionary, item_name: String) -> int:
	for product: Dictionary in Prototypes.recipe_products(recipe):
		if str(product.get("name", "")) == item_name \
				and str(product.get("type", "item")) == "item":
			return maxi(0, int(product.get("amount", 1)))
	return 0


## Plan one recipe run, recursively adding prerequisite tasks before it.
##
## ``virtual`` is the planner's item ledger: ingredients are taken from it and
## subcraft outputs are added to it, so repeated Shift clicks see the extra
## gear wheels produced by a batch as well.  The real inventory is untouched.
func _plan_recipe(recipe_name: String, runs: int, virtual: Dictionary,
		tasks: Array, visiting: Dictionary) -> bool:
	if runs <= 0:
		return true
	if visiting.has(recipe_name) or visiting.size() > 16:
		return false
	var recipe := Prototypes.get_p("recipe", recipe_name)
	if recipe.is_empty():
		return false
	var next_visiting := visiting.duplicate()
	next_visiting[recipe_name] = true

	for ingredient: Dictionary in Prototypes.recipe_ingredients(recipe):
		if str(ingredient.get("type", "item")) != "item":
			return false
		var item_name := str(ingredient.get("name", ""))
		var need := int(ingredient.get("amount", 0)) * runs
		if need <= 0:
			continue
		var available := int(virtual.get(item_name, 0))
		var used := mini(available, need)
		if used > 0:
			virtual[item_name] = available - used
			need -= used
		if need <= 0:
			continue
		var child_name := _recipe_for_item(item_name, next_visiting)
		if child_name.is_empty():
			return false
		var child_recipe := Prototypes.get_p("recipe", child_name)
		var made_amount := _product_amount(child_recipe, item_name)
		if made_amount <= 0:
			return false
		var child_runs := int(ceil(float(need) / float(made_amount)))
		if not _plan_recipe(child_name, child_runs, virtual, tasks, next_visiting):
			return false
		var child_available := int(virtual.get(item_name, 0))
		if child_available < need:
			return false
		virtual[item_name] = child_available - need

	for product: Dictionary in Prototypes.recipe_products(recipe):
		if str(product.get("type", "item")) != "item":
			continue
		var name := str(product.get("name", ""))
		if name.is_empty():
			continue
		virtual[name] = int(virtual.get(name, 0)) \
			+ int(product.get("amount", 1)) * runs

	tasks.append({
		"recipe": recipe_name,
		"count": maxi(1, runs),
		"progress": 0.0,
		"started": false,
	})
	return true


func _tick_crafting(delta: float) -> void:
	if craft_queue.is_empty():
		return
	var head: Dictionary = craft_queue[0]
	var recipe := Prototypes.get_p("recipe", str(head["recipe"]))
	if recipe.is_empty():
		craft_queue.pop_front()
		return
	var runs := maxi(1, int(head.get("count", 1)))
	if not bool(head.get("started", false)):
		# Ingredients were not removed at queue time: a subcraft may have to
		# produce them first.  Reserve/consume them when this task starts.
		for ingredient: Dictionary in Prototypes.recipe_ingredients(recipe):
			if str(ingredient.get("type", "item")) != "item":
				continue
			if inventory.count_of(str(ingredient["name"])) \
					< int(ingredient.get("amount", 0)) * runs:
				return
		for ingredient: Dictionary in Prototypes.recipe_ingredients(recipe):
			if str(ingredient.get("type", "item")) != "item":
				continue
			inventory.extract(str(ingredient["name"]),
				int(ingredient.get("amount", 0)) * runs)
		head["started"] = true
		inventory_changed.emit()
	var seconds := Prototypes.recipe_energy(recipe) / maxf(hand_crafting_speed(), 1e-6)
	head["progress"] = float(head["progress"]) + delta / maxf(seconds, 1e-6)
	if float(head["progress"]) < 1.0:
		return
	craft_queue.pop_front()
	for product: Dictionary in Prototypes.recipe_products(recipe):
		var amount := int(product.get("amount", 1)) * runs
		var leftover := inventory.insert(str(product["name"]), amount)
		# Hand crafting shows up in the production figures too.
		if simulation != null and simulation.statistics != null:
			simulation.statistics.record_produced(str(product["name"]),
				amount - leftover)
		if leftover > 0:
			# No room: Factorio drops it on the ground; keep it in the queue
			# result so nothing silently disappears.
			crafted.emit(str(product["name"]), amount - leftover)
		else:
			crafted.emit(str(product["name"]), amount)
		# Hand crafting counts towards trigger technologies.
		if research != null:
			research.on_item_produced(str(product["name"]), amount - leftover)
	inventory_changed.emit()

## Progress of the craft currently being made, for the queue display.
func crafting_progress() -> float:
	if craft_queue.is_empty():
		return -1.0
	return float((craft_queue[0] as Dictionary).get("progress", 0.0))


## Recipes the player could hand craft right now, ordered like Factorio's
## crafting menu (item group, then subgroup, then recipe order).
func craftable_recipes() -> Array:
	var categories := hand_crafting_categories()
	var out: Array = []
	for recipe_name: String in Prototypes.names("recipe"):
		var recipe := Prototypes.get_p("recipe", recipe_name)
		if research != null and not research.is_recipe_unlocked(recipe_name):
			continue
		if not categories.has(str(recipe.get("category", "crafting"))):
			continue
		var products := Prototypes.recipe_products(recipe)
		if products.is_empty():
			continue
		var product := str(products[0]["name"])
		var item := Prototypes.item_proto(product)
		if item.is_empty():
			continue
		out.append({
			"name": recipe_name,
			"product": product,
			"group": Prototypes.item_group(product),
			"sort_key": Prototypes.item_sort_key(product),
			"craftable": can_hand_craft(recipe_name),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["sort_key"]) < str(b["sort_key"]))
	return out
