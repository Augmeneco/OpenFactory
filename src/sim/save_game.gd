class_name SaveGame
extends RefCounted
## Saving and loading a factory.
##
## The whole world state is plain data — tile ids, ore amounts, entity states,
## research progress, the player's inventory — so it round-trips through JSON
## with only two tricks: the chunk grids are packed byte arrays shipped as
## base64, and ``Inventory`` objects are written out as slot lists and rebuilt
## from the prototypes on load.

const VERSION := 1
const MAGIC := "openfactory-save"
const SAVE_DIR := "user://saves"
const LEGACY_SAVE_PATH := "user://openfactory-save.json"


# --------------------------------------------------------------------------
# capture
# --------------------------------------------------------------------------

static func capture(world: GameWorld, sim: Simulation, research: Research,
		player: Player, character: Character, tick: int) -> Dictionary:
	var chunks: Array = []
	for coord: Vector2i in world._chunks:
		var chunk: GameWorld.Chunk = world._chunks[coord]
		chunks.append({
			"coord": [coord.x, coord.y],
			"tiles": Marshalls.raw_to_base64(chunk.tiles),
			"ore": Marshalls.raw_to_base64(chunk.ore),
			"amount": Marshalls.raw_to_base64(chunk.amount.to_byte_array()),
		})

	var entities: Array = []
	for entity: Entity in world.entities.values():
		entities.append({
			"type": entity.proto_type,
			"name": entity.name,
			"origin": [entity.origin.x, entity.origin.y],
			"direction": entity.direction,
			"state": _encode_state(entity.state),
		})

	return {
		"magic": MAGIC,
		"version": VERSION,
		"factorio_version": str(Prototypes.manifest.get("mods", {}).get("base", "")),
		"seed": world.seed,
		"generator": {
			"water": world.generator.water,
			"moisture": world.generator.moisture,
			"tree_density": world.generator.tree_density,
			"ores": world.generator.ore_settings.duplicate(true),
		},
		"evolution_speed": sim.evolution_speed,
		"enemy_safe_chunks": sim.enemy_safe_chunks,
		"enemy_safe_center": [sim.enemy_safe_center.x, sim.enemy_safe_center.y],
		"tick": tick,
		"palette": Array(world.palette),
		"chunks": chunks,
		"revealed_chunks": _capture_revealed(world),
		"entities": entities,
		"research": {
			"researched": research.researched.keys(),
			"current": research.current,
			"units_done": research.units_done,
			"work": research.work,
			"produced": research.produced,
			"built": research.built,
			"mined_entities": research.mined_entities,
		},
		"player": _capture_player(player),
		"character": _capture_character(character),
		"pollution": sim.pollution.to_dict(),
		"evolution": sim.evolution,
		"elapsed_seconds": sim._elapsed_seconds,
		"pollution_produced": sim._pollution_produced,
		"units": _capture_units(sim),
		"logistics": sim.logistics.to_dict(),
		"trains": sim.trains.to_dict(),
		"statistics": sim.statistics.to_dict(),
		"day": sim.day.to_dict(),
		"rockets_launched": sim.rockets_launched,
		"victory_announced": sim.victory_announced,
	}


static func _capture_revealed(world: GameWorld) -> Array:
	var out: Array = []
	for coord: Vector2i in world.revealed_chunks:
		out.append([coord.x, coord.y])
	return out


## Biters carry references to the entity they are chewing and to their nest;
## both are written as an origin so the record stays plain JSON.
static func _capture_units(sim: Simulation) -> Array:
	var out: Array = []
	for unit: Dictionary in sim.units:
		var record := {
			"name": str(unit.get("name", "")),
			"position": [Vector2(unit["position"]).x, Vector2(unit["position"]).y],
			"direction": int(unit.get("direction", 8)),
			"health": float(unit.get("health", 0.0)),
			"max_health": float(unit.get("max_health", 0.0)),
			"cooldown": int(unit.get("cooldown", 0)),
			"animation": float(unit.get("animation", 0.0)),
		}
		var spawner: Variant = unit.get("spawner")
		record["spawner"] = [spawner.origin.x, spawner.origin.y] \
			if spawner is Entity else null
		var target: Variant = unit.get("target")
		record["target"] = [target.origin.x, target.origin.y] \
			if target is Entity else null
		out.append(record)
	return out


static func _capture_player(player: Player) -> Dictionary:
	if player == null:
		return {}
	return {
		"inventory": player.inventory.to_dict(),
		"cursor": player.cursor_item,
		"quickbar": player.quickbar,
		"selected_slot": player.selected_slot,
		"build_direction": player.build_direction,
		"craft_queue": player.craft_queue,
	}


static func _capture_character(character: Character) -> Dictionary:
	if character == null:
		return {}
	return {
		"position": [character.position.x, character.position.y],
		"direction": character.direction,
		"colour": [character.colour.r, character.colour.g,
			character.colour.b, character.colour.a],
		"health": character.health,
		"max_health": character.max_health,
		"fire_cooldown": character.fire_cooldown,
		"shots_fired": character.shots_fired,
		"equipment": character.equipment.to_dict(),
	}


## Entity state is mostly JSON already; inventories and fluid boxes are not.
static func _encode_state(state: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key: String in state:
		var value: Variant = state[key]
		if value is Inventory:
			out[key] = {"inventory": (value as Inventory).to_dict()}
		elif value is Dictionary and key == "inventories":
			var inventories: Dictionary = {}
			for name: String in value:
				var inv: Variant = value[name]
				if inv is Inventory:
					inventories[name] = (inv as Inventory).to_dict()
			out[key] = {"inventories": inventories}
		else:
			out[key] = value
	return out


# --------------------------------------------------------------------------
# restore
# --------------------------------------------------------------------------

## Whether a dictionary looks like one of our saves.
static func is_valid(data: Dictionary) -> bool:
	return str(data.get("magic", "")) == MAGIC and int(data.get("version", 0)) == VERSION


## Load a save into existing objects, so the scene graph can stay as it is.
## Returns true on success.
static func restore_into(data: Dictionary, world: GameWorld, sim: Simulation,
		research: Research) -> bool:
	if not is_valid(data):
		push_error("SaveGame: not a supported OpenFactory save (version %s)"
			% data.get("version"))
		return false

	world.clear_all()
	world.seed = int(data.get("seed", world.seed))
	world.generator = MapGenerator.new(world.seed)
	var generator_settings: Variant = data.get("generator", {})
	if generator_settings is Dictionary:
		world.generator.apply_settings(generator_settings)
	for tile_name: Variant in data.get("palette", []):
		world.register_tile(str(tile_name))

	for entry: Variant in data.get("chunks", []):
		if not (entry is Dictionary):
			continue
		var coord_values: Array = entry["coord"]
		var loaded := GameWorld.Chunk.new()
		loaded.tiles = Marshalls.base64_to_raw(str(entry["tiles"]))
		loaded.ore = Marshalls.base64_to_raw(str(entry["ore"]))
		loaded.amount = Marshalls.base64_to_raw(str(entry["amount"])).to_float32_array()
		world.install_chunk(Vector2i(int(coord_values[0]), int(coord_values[1])), loaded)

	for entry: Variant in data.get("revealed_chunks", []):
		if entry is Array and (entry as Array).size() >= 2:
			world.reveal_chunk(Vector2i(int(entry[0]), int(entry[1])))

	for entry: Variant in data.get("entities", []):
		if not (entry is Dictionary):
			continue
		var origin_values: Array = entry["origin"]
		var entity := Entity.create(str(entry["type"]), str(entry["name"]),
			Vector2i(int(origin_values[0]), int(origin_values[1])),
			int(entry.get("direction", 0)))
		if not entity.is_valid():
			push_warning("SaveGame: unknown prototype %s/%s" % [entry["type"], entry["name"]])
			continue
		# A ghost goes back as a ghost, so loading a save does not silently
		# build everything the player had only planned.
		var saved_state: Dictionary = entry.get("state", {})
		var is_ghost := bool(saved_state.get("ghost", false))
		var placed := world.place_ghost(entity) if is_ghost \
			else world.place_entity(entity)
		if not placed:
			push_warning("SaveGame: could not place %s at %s" % [entity.name, entity.origin])
			continue
		_decode_state(entity, saved_state)

	research.researched.clear()
	_restore_research(research, data.get("research", {}))

	# Pollution and the biters it drew.
	sim.pollution.from_dict(data.get("pollution", {}))
	sim.evolution_speed = float(data.get("evolution_speed", 1.0))
	sim.enemy_safe_chunks = int(data.get("enemy_safe_chunks", 14))
	var safe_values: Variant = data.get("enemy_safe_center", [0, 0])
	if safe_values is Array and (safe_values as Array).size() >= 2:
		sim.enemy_safe_center = Vector2i(int(safe_values[0]), int(safe_values[1]))
	sim.evolution = float(data.get("evolution", 0.0))
	sim._elapsed_seconds = float(data.get("elapsed_seconds", 0.0))
	sim._pollution_produced = float(data.get("pollution_produced", 0.0))
	sim.units.clear()
	for entry: Variant in data.get("units", []):
		if not (entry is Dictionary):
			continue
		var position_values: Array = entry.get("position", [0.0, 0.0])
		var unit := sim.spawn_unit(str(entry.get("name", "")),
			Vector2(float(position_values[0]), float(position_values[1])))
		if unit.is_empty():
			continue
		unit["direction"] = int(entry.get("direction", 8))
		unit["health"] = float(entry.get("health", unit["health"]))
		unit["max_health"] = float(entry.get("max_health", unit["max_health"]))
		unit["cooldown"] = int(entry.get("cooldown", 0))
		unit["animation"] = float(entry.get("animation", 0.0))
		var spawner_values: Variant = entry.get("spawner")
		if spawner_values is Array and (spawner_values as Array).size() >= 2:
			unit["spawner"] = world.entity_at(Vector2i(int(spawner_values[0]),
				int(spawner_values[1])))
		var target_values: Variant = entry.get("target")
		if target_values is Array and (target_values as Array).size() >= 2:
			var target := world.entity_at(Vector2i(int(target_values[0]),
				int(target_values[1])))
			if target != null:
				unit["target"] = target

	world._rebuild_type_index()
	# Robots are restored after the chests they fly between exist.
	sim.logistics.from_dict(data.get("logistics", {}))
	sim.trains.from_dict(data.get("trains", []))
	sim.statistics.from_dict(data.get("statistics", {}))
	sim.day.from_dict(data.get("day", {}))
	sim.rockets_launched = int(data.get("rockets_launched", 0))
	sim.victory_announced = bool(data.get("victory_announced", false))
	sim.mark_power_dirty()
	sim.fluids.mark_dirty()
	sim.logistics.mark_dirty()
	return true


static func _decode_state(entity: Entity, state: Dictionary) -> void:
	for key: String in state:
		var value: Variant = state[key]
		if key == "inventories" and value is Dictionary and value.has("inventories"):
			var saved: Dictionary = value["inventories"]
			for name: String in saved:
				var inventory := InventoryLayout.get_inventory(entity, name)
				if inventory != null:
					inventory.from_dict(saved[name])
			continue
		if value is Dictionary and value.has("inventory"):
			var restored := Inventory.new()
			restored.from_dict(value["inventory"])
			entity.state[key] = restored
			continue
		entity.state[key] = value


static func _restore_research(research: Research, data: Dictionary) -> void:
	for name: Variant in data.get("researched", []):
		research.researched[str(name)] = true
	research.current = str(data.get("current", ""))
	research.units_done = int(data.get("units_done", 0))
	research.work = float(data.get("work", 0.0))
	research.produced = _int_dict(data.get("produced", {}))
	research.built = _int_dict(data.get("built", {}))
	research.mined_entities = _int_dict(data.get("mined_entities", {}))
	research.rebuild_effects()


static func _int_dict(source: Variant) -> Dictionary:
	var out: Dictionary = {}
	if source is Dictionary:
		for key: String in source:
			out[key] = int(source[key])
	return out


## Put the saved player state back into a freshly created ``Player``.
static func apply_player(player: Player, data: Dictionary) -> void:
	if player == null or data.is_empty():
		return
	if data.has("inventory"):
		player.inventory.from_dict(data["inventory"])
	player.cursor_item = data.get("cursor", {})
	var bar: Variant = data.get("quickbar", [])
	if bar is Array and not bar.is_empty():
		player.quickbar = bar
	# Older saves carry the eight-slot bar; the interface is two rows of ten.
	while player.quickbar.size() < Player.QUICKBAR_SIZE:
		player.quickbar.append("")
	if player.quickbar.size() > Player.QUICKBAR_SIZE:
		player.quickbar.resize(Player.QUICKBAR_SIZE)
	player.selected_slot = clampi(int(data.get("selected_slot", 0)), 0,
		Player.QUICKBAR_SIZE - 1)
	player.build_direction = int(data.get("build_direction", 0))
	var queue: Variant = data.get("craft_queue", [])
	player.craft_queue = queue if queue is Array else []
	# Queues written before recursive crafting had no ``started`` flag: their
	# ingredients were taken at queue time, so they must not be consumed again.
	for entry: Variant in player.craft_queue:
		if entry is Dictionary:
			var queued: Dictionary = entry
			if not queued.has("started"):
				queued["started"] = true
	player.refresh_quickbar()


static func apply_character(character: Character, data: Dictionary) -> void:
	if character == null or data.is_empty():
		return
	var position: Variant = data.get("position", null)
	if position is Array and position.size() >= 2:
		character.position = Vector2(float(position[0]), float(position[1]))
	character.direction = int(data.get("direction", 8))
	if data.has("health"):
		character.health = clampf(float(data["health"]), 0.0,
			character.max_health)
	character.fire_cooldown = int(data.get("fire_cooldown", 0))
	character.shots_fired = int(data.get("shots_fired", 0))
	character.equipment.from_dict(data.get("equipment", {}))
	character.health_changed.emit(character.health, character.max_health)
	var colour: Variant = data.get("colour", null)
	if colour is Array and colour.size() >= 4:
		character.colour = Color(float(colour[0]), float(colour[1]),
			float(colour[2]), float(colour[3]))


# --------------------------------------------------------------------------
# files
# --------------------------------------------------------------------------

## Make sure the named-save directory exists, then list its files newest first.
static func ensure_save_dir() -> void:
	var absolute := ProjectSettings.globalize_path(SAVE_DIR)
	DirAccess.make_dir_recursive_absolute(absolute)


static func sanitize_save_name(display_name: String) -> String:
	var clean := display_name.strip_edges()
	for bad: String in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		clean = clean.replace(bad, "_")
	if clean.is_empty():
		clean = "Save"
	return clean.substr(0, 80)


static func named_save_path(display_name: String) -> String:
	ensure_save_dir()
	return SAVE_DIR.path_join(sanitize_save_name(display_name) + ".json")


## Save under a human-readable name.  Returns the path, or "" on failure.
static func write_named(data: Dictionary, display_name: String) -> String:
	var clean := display_name.strip_edges()
	if clean.is_empty():
		clean = "Save"
	var path := named_save_path(clean)
	data["save_name"] = clean
	data["saved_at"] = Time.get_datetime_string_from_system()
	return path if write_file(path, data) else ""


## Every valid save, newest first, including the old fixed-path save so an
## existing installation can still load its last factory.
static func list_saves() -> Array:
	ensure_save_dir()
	var out: Array = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir != null:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while not file_name.is_empty():
			if not dir.current_is_dir() and file_name.ends_with(".json"):
				var path := SAVE_DIR.path_join(file_name)
				var data := read_file(path)
				if is_valid(data):
					out.append(_save_entry(path, data))
			file_name = dir.get_next()
		dir.list_dir_end()
	if FileAccess.file_exists(LEGACY_SAVE_PATH):
		var legacy := read_file(LEGACY_SAVE_PATH)
		if is_valid(legacy):
			var entry := _save_entry(LEGACY_SAVE_PATH, legacy)
			entry["name"] = "Autosave (legacy)"
			out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["modified"]) > int(b["modified"]))
	return out


static func _save_entry(path: String, data: Dictionary) -> Dictionary:
	var display := str(data.get("save_name", ""))
	if display.is_empty():
		display = path.get_file().get_basename()
	return {
		"path": path,
		"name": display,
		"seed": int(data.get("seed", 0)),
		"tick": int(data.get("tick", 0)),
		"creative": bool(data.get("creative", false)),
		"modified": FileAccess.get_modified_time(path),
		"saved_at": str(data.get("saved_at", "")),
	}


static func latest_save() -> String:
	var saves := list_saves()
	return str(saves[0]["path"]) if not saves.is_empty() else ""


static func has_saves() -> bool:
	return not list_saves().is_empty()


static func write_file(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("SaveGame: cannot write %s" % path)
		return false
	file.store_string(JSON.stringify(data))
	file.close()
	return true


static func read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}
