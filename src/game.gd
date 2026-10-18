extends Node2D
## Game bootstrap.
##
## Builds the world, the renderer, the camera and the simulation, then either
## starts an interactive session or renders a fixed number of frames and
## writes a screenshot / draw dump (used to verify visuals from the command
## line):
##
##   godot --path . -- --screenshot res://tmp_preview/world.png --frames 30
##   godot --headless --path . -- --dump-draw res://tmp_preview/draw.json

const TILE := 32.0

var world: GameWorld
var sim: Simulation
var research: Research
var renderer: WorldRenderer
var camera: GameCamera
var hud: CanvasLayer
var player: Player
var character: Character
var ui_root: Control
var inventory_window: InventoryWindow
var entity_window: EntityWindow
var production_window: ProductionWindow
var equipment_window: EquipmentWindow
var victory_screen: VictoryScreen
var map_window: MapWindow
var objectives: Objectives
var objective_panel: ObjectivePanel
var weapon_panel: WeaponPanel
var recenter_button: Button
## Chunks the player is actively loading around the engineer, and chunks a
## powered radar has scanned.  The renderer/map only show generated chunks.
const PLAYER_CHUNK_RADIUS := 2
const CHUNKS_PER_FRAME := 3
var _chunk_queue: Array[Vector2i] = []
var _chunk_queued: Dictionary = {}
var research_window: ResearchWindow
var minimap: Minimap
var alert_panel: AlertPanel
var toolbar: Toolbar
var tooltips: TooltipLayer
## The night, drawn over the world and under every window.
var night_overlay: ColorRect
var main_menu: MainMenu
var world_settings_dialog: WorldSettingsDialog
var settings_window: SettingsWindow
var game_settings: Dictionary = SettingsWindow.DEFAULTS.duplicate()
var tutorial_enabled := true
var save_load_dialog: SaveLoadDialog
## Where the save/load dialog was opened from, so Cancel returns there.
var _save_dialog_context := "pause"
## True when the current map was started as a creative world.
var creative := false
var pause_menu: PauseMenu
## The item held on the cursor while no inventory window is open.
var _cursor_icon: TextureRect
var _cursor_count: Label
## Frame counter for the throttled, purely cosmetic HUD work.
var _slow_frame := 0

var _screenshot_path := ""
var _screenshot_after := 25
var _frame_counter := 0
var _capturing := false
var _seed := 0
var _spawn_cell := Vector2i(8, 8)
var _dump_path := ""
var _dump_zoom := 1.0
var _warmup_ticks := 0
var _report := false
var _dump_ui := false
var _dump_ui_path := ""
var _dump_ui_screen := "inventory"
## Counts down after a save or load so the HUD can say so.
var _save_flash := 0.0
## Red screen tint after a hit.
var _damage_flash := 0.0
var _hud_dirty := false
var _showroom := ""
## ``--alt`` starts with the ALT overlay on, for the draw dumps.
var _start_with_alt := false
## ``--time`` starts the map at dusk, for the night dumps.
var _set_start_time := false
## ``--minimap-png <path>`` writes the generated minimap image out, since the
## headless UI dump cannot capture a Control that draws itself.
var _minimap_png := ""
## Set by ``--enemy-demo``: the starter factory plus a nest that attacks it.
var _enemy_demo := false
## Set by ``--save`` / ``--load`` for headless round-trip checks.
var _action := ""
## Ticks to run *after* a save or load (``--after``).
var _after_ticks := 0
## Where F5 writes and F9 reads.  ``user://`` sits under the project's own
## data directory, so a save never lands in the source tree.

## Fixed timestep accumulator: the simulation always runs at Factorio's 60 Hz.
var _tick_accumulator := 0.0
var _hud_frame := 0


func _ready() -> void:
	_parse_args()
	randomize()
	if _seed == 0:
		_seed = randi()

	world = GameWorld.new(_seed)
	sim = Simulation.new(world)
	research = Research.new()
	sim.research = research
	if _showroom == "pipes":
		_build_pipe_showroom()
	elif _showroom == "belts":
		_build_belt_showroom()
	elif _showroom == "robots":
		_build_robot_showroom()
	elif _showroom == "ghosts":
		_build_ghost_showroom()
	elif _showroom == "trains":
		_build_train_showroom()
	elif _showroom == "rotate":
		_build_rotate_showroom()
	elif _showroom == "circuits":
		_build_circuit_showroom()
	elif _showroom == "curves":
		_build_curve_showroom()
	else:
		_build_starter_factory()
		if _enemy_demo:
			_build_enemy_demo()

	renderer = WorldRenderer.new()
	renderer.name = "WorldRenderer"
	renderer.world = world
	renderer.simulation = sim
	renderer.show_alt = _start_with_alt
	renderer.require_generated_chunks = true
	renderer.require_revealed_chunks = true
	if _set_start_time:
		sim.day.time_of_day = 0.45
	add_child(renderer)

	camera = GameCamera.new()
	camera.name = "Camera"
	add_child(camera)
	camera.position = (Vector2(_spawn_cell) + Vector2(0.5, 0.5)) * TILE
	camera.make_current()

	player = Player.new()
	player.name = "Player"
	player.world = world
	player.simulation = sim
	player.camera = camera
	add_child(player)
	player.research = research

	# The engineer spawns next to the starter factory and the camera rides
	# along, exactly like Factorio's character view.
	character = Character.new(world, Vector2(_spawn_cell) + Vector2(0.5, 0.5))
	player.attach_character(character)
	renderer.character = character
	# Biters need to know who the engineer is, and death has to mean something.
	sim.character = character
	character.research = research
	character.health_changed.connect(_on_health_changed)
	character.died.connect(_on_engineer_died)
	camera.follow_target = character.world_position()
	camera.position = character.world_position()
	_ensure_character_free()
	_prime_chunks()

	_build_hud()
	_build_ui()
	_load_settings()

	for i in _warmup_ticks:
		sim.step()

	if _action == "save":
		save_game()
	elif _action == "load":
		load_game()
		# Rebuild the power and pipe topology straight away so the loaded
		# factory is consistent before anything reads it.
		sim.power.update()
		sim.fluids.update()

	# Ticks run after the action, to show a loaded factory carrying on.
	for i in _after_ticks:
		sim.step()

	# The title screen, unless a command line asked for something specific.
	if _action.is_empty() and _dump_path.is_empty() and not _dump_ui \
			and not _report and _minimap_png.is_empty() and _showroom.is_empty() \
			and not _enemy_demo:
		_show_main_menu()

	if not _minimap_png.is_empty() and minimap != null:
		minimap.follow(_spawn_cell)
		minimap.rebuild()
		var error := minimap.render_image().save_png(_minimap_png)
		print("minimap: %dx%d -> %s (error %d)" % [minimap.VIEW_TILES.x,
			minimap.VIEW_TILES.y, _minimap_png, error])
		# A picture dump on its own has nothing left to do.
		if _dump_path.is_empty() and not _dump_ui and not _report:
			get_tree().quit(0)
			return

	if _report:
		_print_report()
	if _dump_ui:
		_dump_ui_tree()
	if not _dump_path.is_empty():
		_dump_draw_list()
		get_tree().quit(0)
		return
	if not _screenshot_path.is_empty():
		RenderingServer.frame_post_draw.connect(_on_frame_post_draw)


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--screenshot":
				i += 1
				if i < args.size():
					_screenshot_path = args[i]
			"--frames":
				i += 1
				if i < args.size():
					_screenshot_after = int(args[i])
			"--seed":
				i += 1
				if i < args.size():
					_seed = int(args[i])
			"--dump-draw":
				i += 1
				if i < args.size():
					_dump_path = args[i]
			"--zoom":
				i += 1
				if i < args.size():
					_dump_zoom = float(args[i])
			"--warmup":
				i += 1
				if i < args.size():
					_warmup_ticks = int(args[i])
			"--report":
				_report = true
			"--dump-ui":
				i += 1
				if i < args.size():
					_dump_ui_path = args[i]
				_dump_ui = true
			"--after":
				i += 1
				if i < args.size():
					_after_ticks = int(args[i])
			"--time":
				_set_start_time = true
			"--alt":
				_start_with_alt = true
			"--enemy-demo":
				_enemy_demo = true
			"--minimap-png":
				i += 1
				if i < args.size():
					_minimap_png = args[i]
			"--save":
				_action = "save"
			"--load":
				_action = "load"
			"--showroom":
				i += 1
				if i < args.size():
					_showroom = args[i]
				else:
					_showroom = "pipes"
			"--ui-screen":
				i += 1
				if i < args.size():
					_dump_ui_screen = args[i]
		i += 1


## Human-readable snapshot of every entity, for headless debugging.
func _print_report() -> void:
	print("---- factory report after %d ticks ----" % sim.tick)
	# The engineer and the war for the factory, before the entity list.
	if character != null:
		print("engineer  health %.0f/%.0f  at %s  shots %d  hits taken %d" % [
			character.health, character.max_health, character.position,
			character.shots_fired, int(sim.stats.get("player_hits", 0))])
	var smog := sim.pollution.stats()
	print("pollution %.1f total in %d chunks (worst %.1f), evolution %.1f%%" % [
		float(smog["total"]), int(smog["chunks"]), float(smog["worst"]),
		sim.evolution * 100.0])
	print("combat    %d biters alive, %d spawned, %d killed, %d bites, %d shots" % [
		sim.units.size(), int(sim.stats.get("spawned", 0)),
		int(sim.stats.get("units_killed", 0)), int(sim.stats.get("bites", 0)),
		int(sim.stats.get("shots", 0))])
	var entities: Array = world.entities.values()
	entities.sort_custom(func(a: Entity, b: Entity) -> bool:
		return a.origin.y * 10000 + a.origin.x < b.origin.y * 10000 + b.origin.x)
	for entity: Entity in entities:
		var parts := PackedStringArray()
		parts.append("%-18s %-22s %s dir%-2d" % [entity.proto_type, entity.name,
			entity.origin, entity.direction])
		var inventories: Dictionary = entity.state.get("inventories", {})
		for key: String in inventories:
			var inv: Variant = inventories[key]
			if inv is Inventory and not (inv as Inventory).is_empty():
				var contents := PackedStringArray()
				for slot: Variant in (inv as Inventory).slots:
					if slot != null:
						contents.append("%s x%d" % [slot["name"], int(slot["count"])])
				if contents.size() > 0:
					parts.append("  %s[%s]" % [key, ", ".join(contents)])
		if BeltSim.is_belt(entity):
			parts.append("  belt items %d" % BeltSim.items_of(entity).size())
		if entity.state.has("recipe") and str(entity.state["recipe"]) != "":
			parts.append("  recipe %s @%.0f%%" % [entity.state["recipe"],
				float(entity.state.get("progress", 0.0)) * 100.0])
		elif entity.state.has("progress"):
			parts.append("  progress %.0f%%" % (float(entity.state["progress"]) * 100.0))
		if entity.proto_type == "inserter":
			parts.append("  swing %.2f hand %s pw %.2f" % [
				float(entity.state.get("swing", 0.0)), str(entity.state.get("hand", {})),
				sim.power.satisfaction_for(entity)])
			var proto := entity.prototype()
			parts.append("  pick %s insert %s" % [
				sim._inserter_cell(entity, proto, "pickup_position"),
				sim._inserter_cell(entity, proto, "insert_position")])
		print("   ", " ".join(parts))
	print("   power: %.0f kW generated, %.0f kW demanded, %d networks" % [
		sim.power.total_generation / 1000.0, sim.power.total_demand / 1000.0,
		sim.power.stats()["networks"]])
	print("---------------------------------------")


# --------------------------------------------------------------------------
# main loop
# --------------------------------------------------------------------------

## Lay the time of day over the world.
##
## Night vision is read from the equipment every frame, so taking the goggles
## off lets the dark back in.
func _update_night() -> void:
	if night_overlay == null or sim == null or sim.day == null:
		return
	if player != null and player.character != null:
		sim.day.night_vision = bool(
			player.character.equipment.effects()["night_vision"])
	var wanted := sim.day.tint()
	if night_overlay.color != wanted:
		night_overlay.color = wanted
	# The engineer's flashlight: cut a soft circle out of the night wash.  The
	# wash sits under the HUD, so the circle lights the world and the engineer
	# without touching the interface.
	var material := night_overlay.material as ShaderMaterial
	if material == null or character == null or camera == null:
		return
	var screen: Vector2 = camera.world_to_screen(character.world_position())
	material.set_shader_parameter("overlay_size", night_overlay.size)
	material.set_shader_parameter("flashlight_screen", screen)
	var radius := clampf(330.0 * camera.zoom_level, 120.0, 900.0)
	material.set_shader_parameter("flashlight_radius", radius)
	material.set_shader_parameter("flashlight_softness", radius * 0.8)


## Machine noise, driven straight from the prototypes.
##
## 48 of the placeable types carry sound data.  Belts, pipes and roboports hum
## the whole time they exist; a furnace or an assembler only while it has work.
## The nearest `MAX_LOOPS` win, so a hall of forty furnaces does not become a
## wall of noise.
func _sound_working_machines() -> void:
	if world == null or sim == null:
		return
	var seen: Dictionary = {}
	for entity: Entity in world.entities.values():
		if entity.is_ghost():
			continue
		var centre := Vector2(entity.center())
		if Vector2(FactorioAudio.listener).distance_to(centre) \
				>= FactorioAudio.SILENT_DISTANCE:
			continue
		var proto := entity.prototype()
		var working: Variant = proto.get("working_sound")
		if working == null or not _machine_is_running(entity):
			continue
		var key := "work:%d,%d" % [entity.origin.x, entity.origin.y]
		seen[key] = true
		FactorioAudio.loop_at(key, working, centre)
	FactorioAudio.retire_loops(seen)


## Whether a machine is making its working noise.
##
## Some things are always on — a belt runs whenever it is powered — and some
## only while they have a job.
func _machine_is_running(entity: Entity) -> bool:
	if entity.proto_type in ALWAYS_ON:
		return true
	if entity.state.has("working"):
		return bool(entity.state["working"])
	if entity.state.has("progress"):
		return float(entity.state["progress"]) > 0.0
	return false


## Machine types that hum the whole time they stand there.
const ALWAYS_ON := ["transport-belt", "underground-belt", "splitter", "pipe",
	"pipe-to-ground", "pump", "roboport", "radar", "storage-tank"]


## The soundtrack follows the title screen and the factory's research era.
func _update_music_context() -> void:
	if main_menu != null and main_menu.visible:
		FactorioAudio.set_music_context("menu")
		return
	if research == null:
		return
	var researched := research.researched.size()
	if researched < 30:
		FactorioAudio.set_music_context("early")
	elif researched < 120:
		FactorioAudio.set_music_context("mid")
	else:
		FactorioAudio.set_music_context("late")


func _process(delta: float) -> void:
	# Sounds are placed by where the camera is, so follow it every frame.
	FactorioAudio.listener = camera.position / TILE
	_update_music_context()
	_update_chunk_loading()
	_slow_frame += 1
	# Nothing on the HUD or in the positional audio needs 60 Hz, and both walk
	# the whole entity list; running them at 10 Hz takes a real slice off the
	# frame time once the factory grows.
	if _slow_frame % 6 == 0:
		_sound_working_machines()
	_update_night()
	# Run the factory at a fixed 60 Hz regardless of frame rate, with a cap so
	# a long stall cannot spiral into thousands of catch-up ticks.
	_tick_accumulator += delta
	var budget := 10
	while _tick_accumulator >= Simulation.TICK_DELTA and budget > 0:
		sim.step()
		_tick_accumulator -= Simulation.TICK_DELTA
		budget -= 1
	if budget == 0:
		_tick_accumulator = 0.0
	if player != null:
		player.input_blocked = ui_is_open()
		player.inventory_open = inventory_window.visible
		player.tick(delta)
		if renderer != null:
			# The car replaces the engineer on screen while driving.
			renderer.character = null if player.driving != null else character
		if _hud_frame % 30 == 0 and objectives != null and tutorial_enabled:
			# A hint is not a reflex: twice a second is plenty.
			objectives.update()
		if _hud_frame % 15 == 0:
			player.refresh_quickbar()
		_hud_frame += 1
	_update_cursor_item()
	_layout_side_windows()
	if _slow_frame % 6 == 0:
		_update_hud()
	var title_screen := (main_menu != null and main_menu.visible) \
		or (world_settings_dialog != null and world_settings_dialog.visible) \
		or (save_load_dialog != null and save_load_dialog.visible) \
		or (settings_window != null and settings_window.visible)
	# The title screen is not the game: the quickbar, toolbar and objective
	# panel would only sit on top of it.
	if player != null:
		player.set_hud_visible(not title_screen)
	if toolbar != null:
		toolbar.visible = not title_screen
	if objective_panel != null:
		objective_panel.visible = not title_screen and tutorial_enabled
	if weapon_panel != null:
		weapon_panel.visible = not title_screen
	if recenter_button != null:
		var detached := camera != null and not camera.follow_target.is_finite()
		recenter_button.visible = not title_screen and detached
		recenter_button.position = Vector2(
			get_viewport_rect().size.x * 0.5 - 105.0, 74.0)
	if title_screen:
		minimap.visible = false
		alert_panel.visible = false
	elif toolbar != null:
		# The panels follow their toggles, except where there is nothing to show.
		minimap.visible = toolbar.is_on("map")
		alert_panel.visible = toolbar.is_on("alerts") and sim.alerts.total() > 0
	if not _screenshot_path.is_empty():
		_frame_counter += 1


# --------------------------------------------------------------------------
# the starting factory
# --------------------------------------------------------------------------

## Build a small, genuinely working iron line next to the player's spawn:
## a mining drill feeding a belt, an inserter loading a stone furnace and
## another pulling the plates into a chest, all on solar power.  It doubles as
## a live smoke test of the simulation.
func _build_starter_factory() -> void:
	var anchor := _find_factory_anchor()
	if anchor == Vector2i(-1, -1):
		anchor = Vector2i(4, 4)
	# Natural trees and rocks may live in chunks that were not generated yet
	# while the anchor was being searched.  Generate the whole factory area
	# first, then clear it, so no chunk later pops a tree into a machine tile.
	var clear_area := Rect2i(anchor + Vector2i(-8, -10), Vector2i(30, 22))
	_generate_chunk_area(clear_area)
	world.clear_decoratives(clear_area)
	var placed := 0
	# Two mining drills (3x3 each) drop onto the belt through inserters that
	# reach the drill's bottom row.
	# Direction 8 (south) puts the drill's output chute toward the inserter
	# below it.  Default 0 faced the ore patch and looked like it was dumping
	# out of its back.
	placed += _place("mining-drill", "electric-mining-drill",
		anchor + Vector2i(-1, -3), 8)
	placed += _place("inserter", "inserter", anchor, 0)
	placed += _place("mining-drill", "electric-mining-drill",
		anchor + Vector2i(-4, -3), 8)
	placed += _place("inserter", "inserter", anchor + Vector2i(-3, 0), 0)

	# Belt run carrying the ore east towards the furnace.
	for i in range(-4, 9):
		placed += _place("transport-belt", "transport-belt",
			anchor + Vector2i(i, 1), 4)

	placed += _place("inserter", "inserter", anchor + Vector2i(9, 1), 12)
	placed += _place("furnace", "stone-furnace", anchor + Vector2i(10, 0))
	placed += _place("inserter", "inserter", anchor + Vector2i(12, 1), 12)
	placed += _place("container", "iron-chest", anchor + Vector2i(13, 1))

	# A coal chest feeding the furnace's burner slot, so the line actually
	# smelts instead of just piling ore up.
	var coal_chest_cell := anchor + Vector2i(11, -2)
	placed += _place("container", "wooden-chest", coal_chest_cell)
	placed += _place("inserter", "inserter", anchor + Vector2i(11, -1), 0)
	var coal_chest := world.entity_at(coal_chest_cell)
	if coal_chest != null:
		var storage := InventoryLayout.get_inventory(coal_chest, InventoryLayout.STORAGE)
		if storage != null:
			storage.insert("coal", 100)

	# Power: the drill draws 90 kW and the inserters a little more, so three
	# solar panels keep the line at full speed.  The poles must both reach each
	# other (7.5 tiles of wire) and cover every machine (2.5 tiles of supply).
	placed += _place("electric-pole", "small-electric-pole", anchor + Vector2i(-2, 0))
	placed += _place("electric-pole", "small-electric-pole", anchor + Vector2i(4, 0))
	placed += _place("electric-pole", "small-electric-pole", anchor + Vector2i(10, -1))
	for offset in [-3, 0, 3, 6]:
		placed += _place("solar-panel", "solar-panel", anchor + Vector2i(offset, 2))

	# A little scenery and a chest the player starts with.
	placed += _place("container", "wooden-chest", anchor + Vector2i(-4, 2))
	placed += _place("tree", "tree-01", anchor + Vector2i(7, -6))
	placed += _place("tree", "tree-02", anchor + Vector2i(10, -6))
	# Pick the engineer's tile only now: solar panels and poles have already
	# been placed, and choosing it before them is what used to spawn the
	# engineer inside a solar panel.
	_spawn_cell = _find_spawn_cell(anchor + Vector2i(2, 4))
	sim.mark_power_dirty()
	sim.enemy_safe_center = GameWorld.chunk_of(_spawn_cell)
	sim.enforce_start_safe_zone()
	print("starter factory: %d entities placed, spawn %s" % [placed, _spawn_cell])


## Every belt shape side by side: each corner is fed by a belt pointing into
## it, so the picture shows exactly which sprite the neighbour rule picks.
func _build_belt_showroom() -> void:
	var origin := _free_cell_near(Vector2i(0, 0))
	var cases := [
		{"heading": 0, "from": 4},    # north, fed from the east
		{"heading": 0, "from": 12},   # north, fed from the west
		{"heading": 4, "from": 0},    # east, fed from the north
		{"heading": 4, "from": 8},    # east, fed from the south
		{"heading": 8, "from": 4},    # south, fed from the east
		{"heading": 8, "from": 12},   # south, fed from the west
		{"heading": 12, "from": 0},   # west, fed from the north
		{"heading": 12, "from": 8},   # west, fed from the south
	]
	var index := 0
	for entry: Dictionary in cases:
		var base := origin + Vector2i((index % 4) * 8, (index / 4) * 8)
		index += 1
		var heading := int(entry["heading"])
		var from := int(entry["from"])
		_place("transport-belt", "transport-belt", base, heading)
		_place("transport-belt", "transport-belt", base + BeltSim.dir_vector(from),
			posmod(from + 8, 16))
		_place("transport-belt", "transport-belt", base + BeltSim.dir_vector(heading),
			heading)
	# A splitter with both of its outputs, and an underground pair.
	var split_base := origin + Vector2i(2, 12)
	_place("transport-belt", "transport-belt", split_base + Vector2i(-1, 0), 4)
	_place("splitter", "splitter", split_base, 4)
	_place("transport-belt", "transport-belt", split_base + Vector2i(1, 0), 4)
	_place("transport-belt", "transport-belt", split_base + Vector2i(1, 1), 4)

	var under_base := origin + Vector2i(12, 12)
	_place("transport-belt", "transport-belt", under_base + Vector2i(-1, 0), 4)
	_place("underground-belt", "underground-belt", under_base, 4)
	_place("underground-belt", "underground-belt", under_base + Vector2i(4, 0), 4)
	_place("transport-belt", "transport-belt", under_base + Vector2i(5, 0), 4)
	# Something for the underground belt to tunnel under.
	_place("transport-belt", "transport-belt", under_base + Vector2i(2, 0), 0)

	_spawn_cell = origin + Vector2i(14, 6)
	print("belt showroom: %d belts, %d splitters, %d underground" % [
		world.entities_of_type("transport-belt").size(),
		world.entities_of_type("splitter").size(),
		world.entities_of_type("underground-belt").size()])


## An L of track with both hands of curve, so a train can be seen going round.
func _build_curve_showroom() -> void:
	var base := _free_cell_near(Vector2i(0, 0))
	# South along the left, a clockwise curve, then east.
	var rails: Array = []
	for i in 5:
		var rail := Entity.create("straight-rail", "straight-rail",
			base + Vector2i(0, i * 2), 8)
		if world.place_entity(rail):
			rails.append(rail)
	var bend := Entity.create("curved-rail-a", "curved-rail-a",
		base + Vector2i(0, 10), 0)
	world.place_entity(bend)
	for i in 6:
		var rail := Entity.create("straight-rail", "straight-rail",
			base + Vector2i(2 + i * 2, 10), 12)
		if world.place_entity(rail):
			rails.append(rail)
	# A second, mirror-image bend just to show the other hand.
	var mirror := Entity.create("curved-rail-b", "curved-rail-b",
		base + Vector2i(14, 10), 2)
	world.place_entity(mirror)

	if rails.size() > 6:
		var train := sim.trains.add_train(
			["locomotive", "cargo-wagon", "cargo-wagon"], rails[0], 8)
		for i in 220:
			sim.trains.drive(train, 0.4)
			sim.step()
	_spawn_cell = base + Vector2i(6, 16)
	print("curve showroom: %d rails, %d trains" % [
		world.entities_of_type("straight-rail").size(), sim.trains.trains.size()])


## A wired circuit: a chest read by a constant-fed decider, and a lamp-like
## chain of combinators, so the red and green wires are visible on the ground.
func _build_circuit_showroom() -> void:
	var base := _free_cell_near(Vector2i(0, 0))
	var chest := Entity.create("container", "wooden-chest", base + Vector2i(0, 0), 0)
	world.place_entity(chest)
	var storage := InventoryLayout.get_inventory(chest, InventoryLayout.STORAGE)
	storage.insert("iron-plate", 120)
	chest.state["read_contents"] = true

	var constant := Entity.create("constant-combinator", "constant-combinator",
		base + Vector2i(0, 6), 0)
	world.place_entity(constant)
	constant.state["signals"] = {"signal-A": 5}

	var decider := Entity.create("decider-combinator", "decider-combinator",
		base + Vector2i(6, 2), 0)
	world.place_entity(decider)
	decider.state["decider"] = {"left": "iron-plate", "cmp": ">", "right": "100",
		"out": "signal-G", "value": 1}

	var arithmetic := Entity.create("arithmetic-combinator", "arithmetic-combinator",
		base + Vector2i(12, 6), 0)
	world.place_entity(arithmetic)
	arithmetic.state["arithmetic"] = {"left": "signal-G", "op": "*",
		"right": "10", "out": "signal-A"}

	sim.circuits.add_wire(chest, decider, CircuitNetwork.GREEN)
	sim.circuits.add_wire(constant, decider, CircuitNetwork.RED)
	sim.circuits.add_wire(decider, arithmetic, CircuitNetwork.GREEN)
	# A counter, wired to itself.
	var counter := Entity.create("arithmetic-combinator",
		"arithmetic-combinator", base + Vector2i(12, 0), 0)
	world.place_entity(counter)
	counter.state["arithmetic"] = {"left": "signal-A", "op": "+", "right": "1",
		"out": "signal-A"}
	sim.circuits.add_wire(counter, counter, CircuitNetwork.RED)
	sim.circuits.add_wire(counter, arithmetic, CircuitNetwork.RED)

	for i in 30:
		sim.step()
	_spawn_cell = base + Vector2i(4, 10)
	print("circuit showroom: %d wires, %d red and %d green networks" % [
		sim.circuits.wire_count(), int(sim.circuits.stats()["red_networks"]),
		int(sim.circuits.stats()["green_networks"])])


## The same machines facing all four ways, so a rotation that does not reach
## the art is obvious at a glance.
func _build_rotate_showroom() -> void:
	var base := _free_cell_near(Vector2i(0, 0))
	var rows: Array = [
		["transport-belt", "transport-belt"],
		["inserter", "inserter"],
		["electric-mining-drill", "electric-mining-drill"],
		["stone-furnace", "stone-furnace"],
		["assembling-machine-1", "assembling-machine-1"],
		["splitter", "splitter"],
		["underground-belt", "underground-belt"],
		["steel-furnace", "steel-furnace"],
	]
	for row_index in rows.size():
		var entry: Array = rows[row_index]
		var proto_type := Player.placeable_type(str(entry[0]))
		if proto_type.is_empty():
			proto_type = str(entry[0])
		for i in 4:
			var cell := base + Vector2i(i * 5, row_index * 4)
			var entity := Entity.create(proto_type, str(entry[1]), cell, i * 4)
			if not entity.is_valid():
				continue
			world.place_entity(entity)
			if proto_type == "assembling-machine":
				entity.state["recipe"] = "iron-gear-wheel"
	_spawn_cell = base + Vector2i(2, rows.size() * 4 + 3)
	print("rotate showroom: %d machines facing four ways" % [
		world.entities.size()])


## A length of track with a train standing on it.
func _build_train_showroom() -> void:
	var base := _free_cell_near(Vector2i(0, 0))
	# A straight track running east.
	var rails: Array = []
	for i in 14:
		var rail := Entity.create("straight-rail", "straight-rail",
			base + Vector2i(4 * i, 0), 4)
		if world.place_entity(rail):
			rails.append(rail)
	if rails.size() >= 8:
		# Two stations, so the train is running to a schedule rather than
		# just rolling.
		var alpha := _add_station(base + Vector2i(8, -4), 4, "Iron ore")
		var beta := _add_station(base + Vector2i(44, -4), 4, "Smelting")
		var train := sim.trains.add_train(
			["locomotive", "cargo-wagon", "cargo-wagon"], rails[2], 4)
		train["schedule"] = ["Iron ore", "Smelting"]
		train["automatic"] = true
		train["schedule_index"] = 1
		for i in 90:
			sim.step()
		print("train showroom: stations at %s and %s" % [alpha, beta])
	_spawn_cell = base + Vector2i(24, 10)
	print("train showroom: %d rails, %d trains" % [
		world.entities_of_type("straight-rail").size(), sim.trains.trains.size()])


## A named train stop beside the track.
func _add_station(cell: Vector2i, direction: int, name: String) -> Vector2i:
	var stop := Entity.create("train-stop", "train-stop", cell, direction)
	if not world.place_entity(stop):
		return Vector2i(-1, -1)
	stop.state["station"] = name
	return cell


## The starter factory copied and pasted empty-handed, so the copy stands
## beside the original as ghosts.
func _build_ghost_showroom() -> void:
	_build_starter_factory()
	# Copy a strip of the factory.
	var rect := Rect2i(_spawn_cell + Vector2i(-10, -4), Vector2i(26, 12))
	var blueprint := Blueprints.capture(world, rect)
	# Paste it with an empty inventory: everything becomes a ghost.
	var result := Blueprints.place(world, blueprint,
		_spawn_cell + Vector2i(-10, 10), Inventory.new(1))
	# A roboport and a chest of materials, so construction robots can start
	# working through the plans while the picture is taken.
	var yard := _free_cell_near(_spawn_cell + Vector2i(4, 16))
	world.place_entity(Entity.create("roboport", "roboport", yard, 0))
	var store := Entity.create("logistic-container", "passive-provider-chest",
		yard + Vector2i(0, 5), 0)
	world.place_entity(store)
	var storage := InventoryLayout.get_inventory(store, InventoryLayout.STORAGE)
	for item: Array in [["stone", 200], ["iron-plate", 200],
			["iron-gear-wheel", 200], ["transport-belt", 200],
			["stone-furnace", 20], ["burner-mining-drill", 20],
			["small-electric-pole", 50], ["solar-panel", 50]]:
		storage.insert(str(item[0]), int(item[1]))
	# The personal roboport answers to the engineer, so the network needs a
	# handle on them.
	sim.logistics.player = player
	sim.logistics.mark_dirty()
	print("ghost showroom: copied %d, pasted %d ghosts, roboport at %s" % [
		(blueprint["entities"] as Array).size(),
		(result["ghosts"] as Array).size(), yard])


## A roboport, a provider and a requester, with robots in the air.
func _build_robot_showroom() -> void:
	_spawn_cell = _free_cell_near(Vector2i(0, 0)) + Vector2i(10, 0)
	var base := _spawn_cell
	world.place_entity(Entity.create("roboport", "roboport", base, 0))
	var provider := Entity.create("logistic-container", "passive-provider-chest",
		base + Vector2i(9, -4), 0)
	world.place_entity(provider)
	InventoryLayout.get_inventory(provider, InventoryLayout.STORAGE).insert(
		"iron-plate", 400)
	var requester := Entity.create("logistic-container", "requester-chest",
		base + Vector2i(9, 4), 0)
	world.place_entity(requester)
	requester.state["requests"] = {"iron-plate": 400}
	sim.logistics.mark_dirty()
	# Fly for a while, then stop mid-errand so the picture has robots in it.
	print("robot showroom: %d robots" % sim.logistics.robots.size())


## One of every pipe connection shape, laid out for visual inspection.
func _build_pipe_showroom() -> void:
	_spawn_cell = _free_cell_near(Vector2i(0, 0)) + Vector2i(6, -4)
	var base := _spawn_cell
	# straights and ends
	for i in 4:
		_place("pipe", "pipe", base + Vector2i(i * 2, 0), 0)
	# a horizontal run
	for i in 4:
		_place("pipe", "pipe", base + Vector2i(i, 3), 0)
	# corners
	_place("pipe", "pipe", base + Vector2i(8, 3), 0)
	_place("pipe", "pipe", base + Vector2i(8, 4), 0)
	_place("pipe", "pipe", base + Vector2i(10, 3), 0)
	_place("pipe", "pipe", base + Vector2i(11, 3), 0)
	_place("pipe", "pipe", base + Vector2i(11, 4), 0)
	# a T junction
	_place("pipe", "pipe", base + Vector2i(14, 3), 0)
	_place("pipe", "pipe", base + Vector2i(15, 3), 0)
	_place("pipe", "pipe", base + Vector2i(16, 3), 0)
	_place("pipe", "pipe", base + Vector2i(15, 2), 0)
	# a cross
	_place("pipe", "pipe", base + Vector2i(19, 3), 0)
	_place("pipe", "pipe", base + Vector2i(18, 3), 0)
	_place("pipe", "pipe", base + Vector2i(20, 3), 0)
	_place("pipe", "pipe", base + Vector2i(19, 2), 0)
	_place("pipe", "pipe", base + Vector2i(19, 4), 0)
	# one lonely pipe
	_place("pipe", "pipe", base + Vector2i(23, 3), 0)
	print("pipe showroom: %d pipes" % world.entities_of_type("pipe").size())


## A spot where a drill placed at ``cell + (-1,-3)`` sits on iron ore and the
## whole line has room.
func _find_factory_anchor() -> Vector2i:
	var ore := _find_ore(Vector2i.ZERO, "iron-ore", 500)
	if ore == Vector2i(-1, -1):
		return ore
	# Walk outwards from the first ore found until the layout fits.
	for step in range(0, 60):
		for angle_index in 12:
			var angle := TAU * float(angle_index) / 12.0
			var candidate := ore + Vector2i(
				int(round(cos(angle) * step)), int(round(sin(angle) * step)))
			if _factory_fits(candidate):
				return candidate
	return ore


func _factory_fits(anchor: Vector2i) -> bool:
	# The whole factory, its two trees and the spawn tile must be on land.
	# Without this check the anchor could sit on a coastline and half of the
	# starter factory was silently rejected by the no-spawn-on-water rule.
	if not _area_all_land(Rect2i(anchor + Vector2i(-6, -7),
			Vector2i(24, 16))):
		return false
	var drill_cell := anchor + Vector2i(-1, -3)
	if not _has_ore_under_drill(drill_cell):
		return false
	# The drill row, the belt run and the solar field must be free.
	for i in range(-4, 9):
		if not _factory_cell_free(anchor + Vector2i(i, 1)):
			return false
	for offset in [-3, 0, 3, 6]:
		for dy in 3:
			for dx in 3:
				if not _factory_cell_free(anchor + Vector2i(offset + dx, 2 + dy)):
					return false
	if str(world.ore_at(anchor + Vector2i(-4, -3))["name"]) != "iron-ore" \
			and not _has_ore_under_drill(anchor + Vector2i(-4, -3)):
		return false
	return true


func _area_all_land(area: Rect2i) -> bool:
	for y in range(area.position.y, area.position.y + area.size.y):
		for x in range(area.position.x, area.position.x + area.size.x):
			var tile := world.tile_at(Vector2i(x, y))
			if tile.begins_with("water") or tile.begins_with("deepwater"):
				return false
	return true


## Trees and rocks do not block the factory search; the area is cleared once
## the anchor is chosen.
func _factory_cell_free(cell: Vector2i) -> bool:
	var entity := world.entity_at(cell)
	return entity == null or GameWorld.is_decorative(entity)


func _has_ore_under_drill(drill_cell: Vector2i) -> bool:
	var proto := Prototypes.get_p("mining-drill", "electric-mining-drill")
	var radius := float(proto.get("resource_searching_radius", 2.49))
	var centre := Vector2(drill_cell) + Vector2(1.5, 1.5)
	var reach := int(ceil(radius))
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var cell := drill_cell + Vector2i(dx, dy)
			if str(world.ore_at(cell)["name"]) != "iron-ore":
				continue
			if (Vector2(cell) + Vector2(0.5, 0.5)).distance_to(centre) <= radius:
				return true
	return false


## A tile the engineer fits on: no machine in a 3x3 area and no water.
func _find_spawn_cell(origin: Vector2i) -> Vector2i:
	for radius in range(0, 48):
		var samples := maxi(radius * 12, 1)
		for step in samples:
			var angle := TAU * float(step) / float(samples)
			var cell := origin + Vector2i(int(round(cos(angle) * radius)),
				int(round(sin(angle) * radius)))
			if _spawn_area_free(cell):
				return cell
	return _free_cell_near(origin)


func _spawn_area_free(cell: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var probe := cell + Vector2i(dx, dy)
			if world.entity_at(probe) != null:
				return false
			var tile := world.tile_at(probe)
			if tile.begins_with("water") or tile.begins_with("deepwater"):
				return false
	return true


## Move the engineer out of a machine, a tree or water, if a save or a spawn
## left them inside something solid.
func _ensure_character_free() -> void:
	if character == null:
		return
	if not character.blocked(character.position):
		return
	var cell := _free_cell_near(character.cell(), 1)
	character.position = Vector2(cell) + Vector2(0.5, 0.5)
	camera.position = character.world_position()
	camera.follow_target = character.world_position()
	print("engineer was stuck; moved to %s" % cell)


## Nearest tile with no machine, no ore and no water — a safe place to stand.
func _free_cell_near(origin: Vector2i, clearance := 0) -> Vector2i:
	for radius in range(0, 40):
		for step in range(0, maxi(radius * 8, 1)):
			var angle := TAU * float(step) / maxf(float(radius * 8), 1.0)
			var cell := origin + Vector2i(int(round(cos(angle) * radius)),
				int(round(sin(angle) * radius)))
			if world.entity_at(cell) != null:
				continue
			var tile := world.tile_at(cell)
			if tile.begins_with("water") or tile.begins_with("deepwater"):
				continue
			if clearance > 0:
				var blocked := false
				for dy in range(-clearance, clearance + 1):
					for dx in range(-clearance, clearance + 1):
						if world.entity_at(cell + Vector2i(dx, dy)) != null:
							blocked = true
							break
					if blocked:
						break
				if blocked:
					continue
			return cell
	return origin


func _place(proto_type: String, name: String, cell: Vector2i, direction := 0) -> int:
	var entity := Entity.create(proto_type, name, cell, direction)
	# A chunk generated between the clear and this placement can still contain
	# a natural tree or rock.  Clear just this footprint before placing.
	world.clear_decoratives(Rect2i(cell, entity.size))
	if not world.place_entity(entity):
		push_warning("could not place %s at %s" % [name, cell])
		return 0
	return 1


## Make sure every chunk touched by an area exists, so later placements do
## not trigger generation of decoratives inside it.
func _generate_chunk_area(area: Rect2i) -> void:
	var first := GameWorld.chunk_of(area.position)
	var last := GameWorld.chunk_of(area.position + area.size - Vector2i.ONE)
	for cy in range(first.y, last.y + 1):
		for cx in range(first.x, last.x + 1):
			world.chunk(Vector2i(cx, cy))


func _find_ore(origin: Vector2i, ore_name: String, max_radius: int) -> Vector2i:
	for radius in range(0, max_radius, 8):
		for step in range(0, maxi(radius * 8, 1)):
			var angle := float(step) / maxf(float(radius * 8), 1.0) * TAU
			var cell := origin + Vector2i(
				int(round(cos(angle) * radius)), int(round(sin(angle) * radius)))
			if world.ore_at(cell)["name"] == ore_name:
				return cell
	return Vector2i(-1, -1)


# --------------------------------------------------------------------------
# user interface
# --------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UILayer"
	layer.layer = 3
	add_child(layer)

	ui_root = Control.new()
	ui_root.name = "UIRoot"
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.theme = FactorioStyle.build_theme()
	layer.add_child(ui_root)
	UiKit.fill_parent(ui_root)

	inventory_window = InventoryWindow.new(player)
	inventory_window.name = "InventoryWindow"
	ui_root.add_child(inventory_window)

	entity_window = EntityWindow.new(world, sim, player)
	entity_window.name = "EntityWindow"
	ui_root.add_child(entity_window)
	inventory_window.entity_window = entity_window

	research_window = ResearchWindow.new(research, player)
	research_window.name = "ResearchWindow"
	ui_root.add_child(research_window)

	minimap = Minimap.new()
	minimap.name = "Minimap"
	minimap.world = world
	minimap.character = character
	minimap.camera = camera
	minimap.set_simulation(sim)
	minimap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	minimap.position = Vector2(-minimap.VIEW_TILES.x - 8, 8)
	minimap.size = Vector2(minimap.VIEW_TILES)
	minimap.tile_clicked.connect(_on_minimap_clicked)
	ui_root.add_child(minimap)

	alert_panel = AlertPanel.new()
	alert_panel.name = "AlertPanel"
	alert_panel.alerts = sim.alerts
	alert_panel.camera = camera
	alert_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	alert_panel.position = Vector2(-64, -160)
	alert_panel.alert_clicked.connect(_on_alert_clicked)
	ui_root.add_child(alert_panel)
	sim.alerts_changed.connect(alert_panel.refresh)

	tooltips = TooltipLayer.new()
	tooltips.name = "Tooltips"
	ui_root.add_child(tooltips)

	_build_cursor_icon()
	FactorioAudio.listener = camera.position / TILE

	sim.rocket_launched.connect(_on_rocket_launched)

	production_window = ProductionWindow.new(sim)
	ui_root.add_child(production_window)

	equipment_window = EquipmentWindow.new(player)
	ui_root.add_child(equipment_window)

	victory_screen = VictoryScreen.new()
	ui_root.add_child(victory_screen)

	objectives = Objectives.new(player, world, sim, research)
	objectives.completed.connect(_on_objective_completed)
	weapon_panel = WeaponPanel.new(player)
	weapon_panel.name = "WeaponPanel"
	weapon_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	# The weapon panel owns the very bottom-left corner; the tutorial panel is
	# stacked above it, so hiding the tutorial does not leave a floating panel.
	weapon_panel.offset_left = 12
	weapon_panel.offset_right = 12 + 210
	weapon_panel.offset_bottom = -12
	weapon_panel.offset_top = -12 - 112
	weapon_panel.equipment_requested.connect(func() -> void:
		if player != null and player.character != null \
				and player.character.equipment.width > 0 \
				and player.character.equipment.height > 0:
			equipment_window.open_window())
	hud.add_child(weapon_panel)

	objective_panel = ObjectivePanel.new(objectives)
	objective_panel.name = "Objective"
	hud.add_child(objective_panel)
	# Directly above the weapon panel: the tutorial is separate, so turning it
	# off never moves the weapon panel away from the corner.
	objective_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	objective_panel.offset_left = 12
	objective_panel.offset_right = 356
	objective_panel.offset_top = -292
	objective_panel.offset_bottom = -136

	map_window = MapWindow.new()
	map_window.world = world
	map_window.simulation = sim
	map_window.character = character
	map_window.view_requested.connect(_on_map_view_requested)
	ui_root.add_child(map_window)

	# One chunk-picture cache for both maps: opening the map after the minimap
	# has already rasterised the nearby chunks costs a few blits, not another
	# round of chunk building.
	var shared_chunks := MapChunks.new(world)
	shared_chunks.require_generated = true
	shared_chunks.require_revealed = true
	minimap.set_map_chunks(shared_chunks)
	map_window.set_map_chunks(shared_chunks)

	night_overlay = ColorRect.new()
	night_overlay.name = "Night"
	night_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	night_overlay.color = Color(1, 1, 1, 0)
	var night_shader := load("res://src/render/night_flashlight.gdshader") as Shader
	if night_shader != null:
		var night_material := ShaderMaterial.new()
		night_material.shader = night_shader
		night_overlay.material = night_material
	var night_layer := CanvasLayer.new()
	night_layer.name = "NightLayer"
	# Under the interface: the night tints the world, never the windows.
	night_layer.layer = 1
	add_child(night_layer)
	night_layer.add_child(night_overlay)
	UiKit.fill_parent(night_overlay)

	_build_toolbar()
	_build_menus()

	player.entity_activated.connect(_on_entity_activated)
	get_viewport().size_changed.connect(_on_viewport_resized)


## The item on the cursor, drawn above every window.
##
## The inventory and machine windows have their own copy that lives inside the
## window; this one is what makes an item carried *out* of the inventory
## visible, so it can be seen and placed in the world.
func _build_cursor_icon() -> void:
	var layer := CanvasLayer.new()
	layer.name = "CursorItemLayer"
	layer.layer = 10
	add_child(layer)
	var root := Control.new()
	root.name = "CursorItemRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	UiKit.fill_parent(root)

	_cursor_icon = TextureRect.new()
	_cursor_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cursor_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cursor_icon.custom_minimum_size = Vector2(44, 44)
	_cursor_icon.size = Vector2(44, 44)
	_cursor_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_icon.visible = false
	root.add_child(_cursor_icon)

	_cursor_count = Label.new()
	_cursor_count.add_theme_font_override("font", FactorioStyle.font("default"))
	_cursor_count.add_theme_font_size_override("font_size", 14)
	_cursor_count.add_theme_color_override("font_color", Color(1, 1, 1))
	_cursor_count.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_cursor_count.add_theme_constant_override("outline_size", 4)
	_cursor_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_count.visible = false
	root.add_child(_cursor_count)


func _update_cursor_item() -> void:
	if _cursor_icon == null or player == null:
		return
	var held := player.cursor_item
	var covered_by_window := inventory_window.visible or entity_window.visible
	if held.is_empty() or covered_by_window:
		_cursor_icon.visible = false
		_cursor_count.visible = false
		return
	var item_name := str(held.get("name", ""))
	_cursor_icon.texture = FactorioAssets.icon_for("item", item_name, 64)
	var mouse := get_viewport().get_mouse_position()
	_cursor_icon.position = mouse - Vector2(22, 22)
	_cursor_icon.visible = _cursor_icon.texture != null
	_cursor_count.text = str(int(held.get("count", 0)))
	_cursor_count.position = mouse + Vector2(8, 10)
	_cursor_count.visible = int(held.get("count", 0)) > 1


func _on_viewport_resized() -> void:
	if ui_root != null:
		UiKit.refill(ui_root)


func _on_entity_activated(entity: Entity) -> void:
	if BeltSim.is_belt(entity):
		return
	entity_window.toggle_window(entity)
	if entity_window.visible:
		# Factorio opens the character screen beside a chest or furnace so a
		# stack can be dragged straight from the pockets into the machine.
		inventory_window.open_window()
	else:
		inventory_window.close_window()


## Lay the machine window and the character inventory side by side while both
## are open.  The CenterContainers re-centre them on layout, so this runs every
## frame; it is two position assignments, not a rebuild.
func _layout_side_windows() -> void:
	if inventory_window == null or entity_window == null:
		return
	if not (inventory_window.visible and entity_window.visible):
		if inventory_window.suppress_cursor:
			inventory_window.suppress_cursor = false
			inventory_window._refresh_cursor()
		return
	var inv_size := inventory_window.frame_size()
	var ent_size := entity_window.frame_size()
	if inv_size.x <= 1.0 or ent_size.x <= 1.0:
		return
	var viewport := get_viewport().get_visible_rect().size
	var gap := 16.0
	var total := inv_size.x + ent_size.x + gap
	var left := maxf(8.0, (viewport.x - total) * 0.5)
	inventory_window.place_frame(Vector2(left,
		maxf(8.0, (viewport.y - inv_size.y) * 0.5)))
	entity_window.place_frame(Vector2(left + inv_size.x + gap,
		maxf(8.0, (viewport.y - ent_size.y) * 0.5)))
	# Only the machine window draws the carried-item cursor while both are
	# visible, otherwise the icon is painted twice.
	if not inventory_window.suppress_cursor:
		inventory_window.suppress_cursor = true
		inventory_window._refresh_cursor()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	match key.keycode:
		KEY_E:
			if entity_window.visible:
				entity_window.close_window()
			else:
				inventory_window.toggle()
		KEY_G:
			# Equipment used to be bound to a second KEY_E arm, which Godot
			# matched first — the window could never open.
			equipment_window.toggle()
		KEY_M:
			map_window.toggle(character.cell() if character != null
				else _spawn_cell)
		KEY_P:
			production_window.toggle()
		KEY_T:
			research_window.toggle()
		KEY_ALT:
			# Factorio's ALT mode: what each machine is set to make.
			renderer.show_alt = not renderer.show_alt
			toolbar.set_alt(renderer.show_alt)
		KEY_C, KEY_SPACE:
			player.shoot_at(camera.mouse_world_position())
		KEY_HOME:
			# Clicking the map lets the camera go, and without this there is no
			# way back to the engineer — they end up off screen with nothing to
			# say where they went.
			_centre_on_engineer()
		KEY_F5:
			save_game()
		KEY_F9:
			load_game()
		KEY_ESCAPE:
			if settings_window != null and settings_window.visible:
				settings_window.close_settings()
			elif save_load_dialog != null and save_load_dialog.visible:
				save_load_dialog.visible = false
				_cancel_save_dialog()
			elif world_settings_dialog != null and world_settings_dialog.visible:
				_show_main_menu()
			elif camera != null and not camera.follow_target.is_finite():
				_centre_on_engineer()
			elif pause_menu.visible:
				_close_pause_menu()
			elif player != null and player.item_picker != null \
					and player.item_picker.visible:
				player.item_picker.close_picker()
			elif inventory_window.visible or entity_window.visible \
					or research_window.visible:
				inventory_window.close_window()
				entity_window.close_window()
				research_window.close_window()
			elif player != null and not player.wire_colour.is_empty():
				# Escape puts the wire away before it opens the pause menu, so
				# a forgotten wire cannot keep eating clicks.
				player.cancel_wire()
			else:
				_open_pause_menu()


## Whether a modal window currently owns input.
## Write the whole factory to disk.  F5 uses the "Quicksave" name; the pause
## menu opens the named-save dialog instead.
func save_game(save_name := "Quicksave") -> bool:
	var data := SaveGame.capture(world, sim, research, player, character, sim.tick)
	data["creative"] = creative
	if objectives != null:
		data["objectives"] = {"current": objectives.current}
	var path := SaveGame.write_named(data, save_name)
	if path.is_empty():
		push_warning("could not write save %s" % save_name)
		return false
	var bytes := FileAccess.get_file_as_string(path).length()
	print("saved '%s' (%d entities, %d chunks, tick %d, %.1f kB)" % [
		save_name, world.entities.size(), world.chunk_count(), sim.tick,
		bytes / 1024.0])
	_save_flash = 3.0
	return true


## Read a named save back and rebuild the world in place.  With an empty path
## this loads the newest save, which is what F9 and Continue do.
func load_game(path := "") -> bool:
	if path.is_empty():
		path = SaveGame.latest_save()
	if path.is_empty():
		push_warning("no save to load")
		return false
	var data := SaveGame.read_file(path)
	if data.is_empty():
		push_warning("no save at %s" % path)
		return false
	main_menu.close_menu()
	pause_menu.close_menu()
	save_load_dialog.visible = false
	# Loading from the pause menu must resume the simulation; close_menu()
	# on its own only hides the panel.
	sim.paused = false
	if not SaveGame.restore_into(data, world, sim, research):
		return false
	creative = bool(data.get("creative", false))
	if player != null:
		player.creative = creative
		player.driving = null
	sim.tick = int(data.get("tick", 0))
	if sim.alerts != null:
		sim.alerts.reset()
	player.research = research
	SaveGame.apply_player(player, data.get("player", {}))
	SaveGame.apply_character(character, data.get("character", {}))
	if objectives != null:
		var saved_objectives: Variant = data.get("objectives", null)
		if saved_objectives is Dictionary:
			objectives.current = clampi(int((saved_objectives as Dictionary).get(
				"current", 0)), 0, objectives.total())
		if tutorial_enabled:
			objectives.update()
		if objective_panel != null:
			objective_panel.refresh()
	_ensure_character_free()
	entity_window.close_window()
	inventory_window.close_window()
	research_window.close_window()
	_save_flash = 3.0
	print("loaded '%s' (%d entities, %d chunks, tick %d)" % [
		str(data.get("save_name", path.get_file())), world.entities.size(),
		world.chunk_count(), sim.tick])
	return true


func _open_save_dialog() -> void:
	_save_dialog_context = "pause"
	if pause_menu != null:
		pause_menu.visible = false
	if save_load_dialog != null:
		save_load_dialog.move_to_front()
		save_load_dialog.open_save("Factory " + Time.get_datetime_string_from_system()
			.replace("T", " ").replace(":", "-"))


func _open_load_dialog() -> void:
	_save_dialog_context = "main" if main_menu.visible else "pause"
	if main_menu.visible:
		main_menu.close_menu()
	if pause_menu.visible:
		pause_menu.visible = false
	if save_load_dialog != null:
		save_load_dialog.move_to_front()
		save_load_dialog.open_load()


func _cancel_save_dialog() -> void:
	if save_load_dialog != null:
		save_load_dialog.visible = false
	if _save_dialog_context == "main":
		_show_main_menu()
	elif pause_menu != null and not pause_menu.visible:
		_open_pause_menu()


func _save_named(save_name: String) -> void:
	if save_game(save_name):
		if pause_menu != null and not pause_menu.visible:
			_open_pause_menu()
		if pause_menu != null:
			pause_menu.say("Saved as %s" % save_name)


func _load_named(path: String) -> void:
	load_game(path)
## A goal was met: tell the player and chime.
func _on_objective_completed(_index: int, title: String) -> void:
	if not tutorial_enabled:
		return
	print("objective met: %s" % title)
	FactorioAudio.play_utility("new_objective", FactorioAudio.listener)
	objective_panel.refresh()


## A rocket left the pad.
func _on_rocket_launched(number: int) -> void:
	var per_minute := 0.0
	if sim.statistics != null:
		var totals := sim.statistics.totals()
		per_minute = float(totals["items_produced"])
	victory_screen.announce(number, per_minute)
	FactorioAudio.play_utility("achievement_unlocked", FactorioAudio.listener)


## A train carriage was clicked.
func _on_train_activated(train: Dictionary) -> void:
	entity_window.open_train(train)


## The button row beside the quickbar.
func _build_toolbar() -> void:
	toolbar = Toolbar.new()
	toolbar.name = "Toolbar"
	toolbar.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	# Level with the two-row quickbar and clear of it.
	toolbar.position = Vector2(-320, -124)
	toolbar.toggled.connect(_on_toolbar_toggled)
	toolbar.pressed_action.connect(_on_toolbar_pressed)
	ui_root.add_child(toolbar)
	toolbar.set_alt(renderer.show_alt)
	toolbar.set_toggle("ore", renderer.show_ore)
	toolbar.set_toggle("grid", renderer.show_grid)
	toolbar.set_toggle("map", true)
	toolbar.set_toggle("alerts", true)


func _on_toolbar_toggled(name: String, on: bool) -> void:
	match name:
		"alt":
			renderer.show_alt = on
		"ore":
			renderer.show_ore = on
		"grid":
			renderer.show_grid = on
		"objectives":
			# Walk the chain until something is unmet, then show that one.
			for i in 3:
				objectives.update()
			objective_panel.refresh()
		"map":
			minimap.visible = on
		"objectives":
			# Walk the chain until something is unmet, then show that one.
			for i in 3:
				objectives.update()
			objective_panel.refresh()
		"map":
			map_window.visible = true
			map_window.size = get_viewport().get_visible_rect().size
			map_window.build_colours()
			map_window.centre_on(_spawn_cell)
		"victory":
			victory_screen.announce(1, 42.5)
		"equipment":
			# Wear a suit and fit it out, so the grid has something to show.
			if player.inventory.count_of("power-armor-mk2") == 0:
				player.inventory.insert("power-armor-mk2", 1)
			player.equip_armor("power-armor-mk2")
			for piece: String in ["fusion-reactor-equipment",
					"energy-shield-mk2-equipment", "exoskeleton-equipment",
					"personal-roboport-equipment", "battery-mk2-equipment",
					"night-vision-equipment"]:
				if player.inventory.count_of(piece) == 0:
					player.inventory.insert(piece, 1)
				player.fit_equipment(piece)
			player.quickbar[0] = "energy-shield-equipment"
			player.selected_slot = 0
			equipment_window.open_window()
		"production":
			production_window.open_window()
		"tooltip":
			tooltips.preview_card(Tooltips.item_card("assembling-machine-1"),
				Vector2(560, 460))
		"recipe-tooltip":
			tooltips.preview_card(Tooltips.recipe_card("electronic-circuit"),
				Vector2(560, 460))
		"alerts":
			alert_panel.visible = on and sim.alerts.total() > 0


func _on_toolbar_pressed(name: String) -> void:
	if name == "research":
		research_window.toggle()


## The title screen and the in-game menu.
func _build_menus() -> void:
	main_menu = MainMenu.new()
	main_menu.name = "MainMenu"
	main_menu.new_game_requested.connect(_open_world_settings)
	main_menu.continue_requested.connect(_continue_game)
	main_menu.load_requested.connect(_open_load_dialog)
	main_menu.settings_requested.connect(_open_settings_window)
	main_menu.about_requested.connect(_show_about)
	main_menu.quit_requested.connect(func() -> void: get_tree().quit(0))
	ui_root.add_child(main_menu)

	world_settings_dialog = WorldSettingsDialog.new()
	world_settings_dialog.name = "WorldSettings"
	world_settings_dialog.start_requested.connect(func(settings: Dictionary) -> void:
		_start_new_game(settings))
	world_settings_dialog.cancelled.connect(_show_main_menu)
	ui_root.add_child(world_settings_dialog)

	save_load_dialog = SaveLoadDialog.new()
	save_load_dialog.name = "SaveLoad"
	save_load_dialog.save_requested.connect(_save_named)
	save_load_dialog.load_requested.connect(_load_named)
	save_load_dialog.cancelled.connect(_cancel_save_dialog)
	save_load_dialog.z_index = 100
	ui_root.add_child(save_load_dialog)

	pause_menu = PauseMenu.new()
	pause_menu.name = "PauseMenu"
	pause_menu.resume_requested.connect(_close_pause_menu)
	pause_menu.save_requested.connect(_open_save_dialog)
	pause_menu.load_requested.connect(_open_load_dialog)
	pause_menu.settings_requested.connect(_open_settings_window)
	pause_menu.quit_requested.connect(_quit_to_menu)
	ui_root.add_child(pause_menu)

	settings_window = SettingsWindow.new()
	settings_window.name = "SettingsWindow"
	settings_window.changed.connect(_on_settings_changed)
	settings_window.closed.connect(_save_settings)
	ui_root.add_child(settings_window)


func _open_settings_window() -> void:
	if settings_window == null:
		return
	settings_window.open_settings(game_settings)


func _on_settings_changed(values: Dictionary) -> void:
	game_settings = values
	_apply_settings()
	_save_settings()


func _load_settings() -> void:
	game_settings = SettingsWindow.DEFAULTS.duplicate()
	var path := "user://settings.json"
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			var parsed: Variant = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary:
				for key: String in SettingsWindow.DEFAULTS:
					if (parsed as Dictionary).has(key):
						game_settings[key] = parsed[key]
	_apply_settings()


func _save_settings() -> void:
	var file := FileAccess.open("user://settings.json", FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(game_settings, "\t"))


func _apply_settings() -> void:
	FactorioAudio.master_volume = clampf(
		float(game_settings.get("sound_volume", 0.9)), 0.0, 1.0)
	FactorioAudio.music_volume = clampf(
		float(game_settings.get("music_volume", 0.85)), 0.0, 1.0)
	tutorial_enabled = bool(game_settings.get("tutorial_enabled", true))
	if objective_panel != null:
		objective_panel.visible = tutorial_enabled
	if renderer != null:
		renderer.ground_lod_threshold = clampf(
			float(game_settings.get("tile_lod_zoom", 0.70)), 0.20, 1.0)


## Mark everything around a point as satellite-explored.
func _reveal_chunks_around(cell: Vector2i, radius: int) -> void:
	var centre := GameWorld.chunk_of(cell)
	for cy in range(centre.y - radius, centre.y + radius + 1):
		for cx in range(centre.x - radius, centre.x + radius + 1):
			world.reveal_chunk(Vector2i(cx, cy))


## Queue every chunk around a point that is not generated yet.
func _queue_chunks_around(cell: Vector2i, radius: int) -> void:
	var centre := GameWorld.chunk_of(cell)
	for cy in range(centre.y - radius, centre.y + radius + 1):
		for cx in range(centre.x - radius, centre.x + radius + 1):
			var coord := Vector2i(cx, cy)
			if world.is_generated(coord) or _chunk_queued.has(coord):
				continue
			_chunk_queued[coord] = true
			_chunk_queue.append(coord)


## Generate a few chunks per frame so the loading screen never freezes.  The
## player keeps a small radius around the engineer loaded; a powered radar
## scans the nearby sector and queues the chunks it reveals.
func _update_chunk_loading() -> void:
	if character != null:
		_reveal_chunks_around(character.cell(), PLAYER_CHUNK_RADIUS)
		_queue_chunks_around(character.cell(), PLAYER_CHUNK_RADIUS)
	if sim.power != null:
		for radar: Entity in world.entities_of_type("radar"):
			if not sim.power.is_powered(radar) \
					or sim.power.satisfaction_for(radar) <= 0.0:
				continue
			var radius := maxi(1, int(radar.prototype().get(
				"max_distance_of_nearby_sector_revealed", 3)))
			_reveal_chunks_around(radar.cell(), radius)
			_queue_chunks_around(radar.cell(), radius)
	var built := 0
	while built < CHUNKS_PER_FRAME and not _chunk_queue.is_empty():
		var coord: Vector2i = _chunk_queue.pop_front()
		_chunk_queued.erase(coord)
		if world.is_generated(coord):
			continue
		world.chunk(coord)
		built += 1


## The starting area is loaded immediately; waiting three chunks per frame
## would leave the camera looking at black terrain for the first second.
func _prime_chunks() -> void:
	_reveal_chunks_around(character.cell(), PLAYER_CHUNK_RADIUS)
	_queue_chunks_around(character.cell(), PLAYER_CHUNK_RADIUS)
	for coord: Vector2i in _chunk_queue:
		if not world.is_generated(coord):
			world.chunk(coord)
	_chunk_queue.clear()
	_chunk_queued.clear()


## Map click: inspect the scanned area from a normal camera close up, with all
## machines and fluid/power machinery still visible and running.
func _on_map_view_requested(cell: Vector2i) -> void:
	var coord := GameWorld.chunk_of(cell)
	if camera == null or not world.is_generated(coord) \
			or not world.is_chunk_revealed(coord):
		return
	map_window.close_window()
	camera.follow_target = Vector2.INF
	camera.position = (Vector2(cell) + Vector2(0.5, 0.5)) * TILE
	camera.zoom = Vector2.ONE
	camera.zoom_level = 1.0


func _open_world_settings() -> void:
	if main_menu != null:
		main_menu.close_menu()
	if player != null:
		player.set_hud_visible(false)
	if toolbar != null:
		toolbar.visible = false
	if objective_panel != null:
		objective_panel.visible = false
	if minimap != null:
		minimap.visible = false
	if alert_panel != null:
		alert_panel.visible = false
	if world_settings_dialog != null:
		world_settings_dialog.open_settings()


func main_menu_version_note(message: String) -> void:
	print(message)


func _show_about() -> void:
	print("OpenFactory — a Factorio clone. Prototypes, recipes, technologies and "
		+ "artwork are read from the local Factorio install; nothing is redistributed.")


## Show the title screen.  The world stays behind it, as in Factorio.
func _show_main_menu() -> void:
	if settings_window != null:
		settings_window.visible = false
	if world_settings_dialog != null:
		world_settings_dialog.visible = false
	main_menu.open(SaveGame.has_saves(),
		"Factorio %s data" % str(Prototypes.manifest.get("mods", {}).get("base", "")))
	pause_menu.close_menu()
	inventory_window.close_window()
	entity_window.close_window()
	research_window.close_window()
	sim.paused = true


func _quit_to_menu() -> void:
	_show_main_menu()


func _close_pause_menu() -> void:
	pause_menu.close_menu()
	sim.paused = false


func _open_pause_menu() -> void:
	pause_menu.open_menu()
	sim.paused = true


## Start a fresh world: new seed, everything cleared, the starter factory laid
## out again.
func _start_new_game(settings: Dictionary = {}) -> void:
	var from_world_settings: bool = world_settings_dialog != null \
		and world_settings_dialog.visible
	if not main_menu.visible and not pause_menu.visible and not from_world_settings:
		return
	sim.paused = false
	main_menu.close_menu()
	pause_menu.close_menu()
	if world_settings_dialog != null:
		world_settings_dialog.visible = false
	inventory_window.close_window()
	entity_window.close_window()
	research_window.close_window()

	_seed = randi() % 1000000
	world.clear_all()
	world.seed = _seed
	world.generator = MapGenerator.new(_seed)
	if settings.is_empty():
		settings = WorldSettingsDialog.default_settings()
	world.generator.apply_settings(settings)
	creative = bool(settings.get("creative", false))
	if player != null:
		player.creative = creative
		player.driving = null
	sim.evolution_speed = float(settings.get("evolution_speed", 1.0))
	sim.enemy_safe_chunks = clampi(int(round(float(settings.get(
		"nest_distance", 14.0)))), 0, 60)
	sim.enemy_safe_center = Vector2i.ZERO
	sim.tick = 0
	if sim.alerts != null:
		sim.alerts.reset()
	sim.evolution = 0.0
	sim._elapsed_seconds = 0.0
	sim._pollution_produced = 0.0
	sim.units.clear()
	sim.pollution.clear()
	sim.logistics.clear()
	sim.reset_stats()
	sim.logistics.mark_dirty()
	sim.fluids.mark_dirty()
	sim.mark_power_dirty()
	research.researched.clear()
	if creative:
		research.unlock_all()
	research.current = ""
	research.units_done = 0
	research.work = 0.0
	research.produced.clear()
	research.built.clear()
	research.mined_entities.clear()
	research.rebuild_effects()

	player.inventory.resize(0)
	player.cursor_item = {}
	player.craft_queue.clear()
	player.refresh_inventory_size()

	_build_starter_factory()
	character.respawn(Vector2(_spawn_cell) + Vector2(0.5, 0.5))
	camera.position = character.world_position()
	camera.follow_target = character.world_position()
	_ensure_character_free()
	player.give_starting_items()
	if objectives != null:
		objectives.current = 0
	if objective_panel != null:
		objective_panel.refresh()
	print("new game: seed %d" % _seed)


func _continue_game() -> void:
	var path := SaveGame.latest_save()
	if path.is_empty():
		_start_new_game()
		return
	main_menu.close_menu()
	sim.paused = false
	load_game(path)


## Put the camera back on the engineer and start following them again.
func _centre_on_engineer() -> void:
	if camera == null or character == null:
		return
	camera.position = character.world_position()
	camera.follow_target = character.world_position()


## Clicking an alert takes the camera to the machine that raised it.
func _on_alert_clicked(cell: Vector2i) -> void:
	if camera == null:
		return
	camera.follow_target = Vector2.INF
	camera.position = (Vector2(cell) + Vector2(0.5, 0.5)) * TILE


## Clicking the minimap jumps the camera there, unless the camera is following
## the engineer — then it lets go first, as Factorio does.
func _on_minimap_clicked(cell: Vector2i) -> void:
	if camera == null:
		return
	camera.follow_target = Vector2.INF
	camera.position = (Vector2(cell) + Vector2(0.5, 0.5)) * TILE


func ui_is_open() -> bool:
	return inventory_window.visible or entity_window.visible \
		or research_window.visible or production_window.visible \
		or equipment_window.visible or victory_screen.visible \
		or map_window.visible or main_menu.visible or pause_menu.visible \
		or (player != null and player.item_picker != null and player.item_picker.visible) \
		or (world_settings_dialog != null and world_settings_dialog.visible) \
		or (save_load_dialog != null and save_load_dialog.visible) \
		or (settings_window != null and settings_window.visible)


# --------------------------------------------------------------------------
# HUD
# --------------------------------------------------------------------------

func _build_hud() -> void:
	hud = CanvasLayer.new()
	hud.name = "HUD"
	# Above the night wash (layer 1), under the windows (layer 3): the objective
	# panel and the debug text must not be darkened by the night.
	hud.layer = 2
	add_child(hud)
	var label := Label.new()
	label.name = "DebugLabel"
	label.position = Vector2(12, 8)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("outline_size", 4)
	hud.add_child(label)

	recenter_button = UiKit.button("Return to engineer", "button")
	recenter_button.visible = false
	recenter_button.custom_minimum_size = Vector2(210, 34)
	recenter_button.position = Vector2(695, 74)
	recenter_button.pressed.connect(_centre_on_engineer)
	hud.add_child(recenter_button)


func _update_hud() -> void:
	var label: Label = hud.get_node_or_null("DebugLabel")
	if label == null or camera == null:
		return
	var mouse_cell := Vector2i(floor(camera.mouse_world_position() / TILE))
	var ore := world.ore_at(mouse_cell)
	label.text = "\n".join([
		"OpenFactory  |  seed %d" % _seed,
		"FPS %d   zoom %.2f" % [Engine.get_frames_per_second(), camera.zoom_level],
		"cell %d, %d   tile %s" % [mouse_cell.x, mouse_cell.y, world.tile_at(mouse_cell)],
		"ore %s %s" % [ore["name"] if ore["name"] != "" else "-", int(ore["amount"])],
		"tick %d   entities %d" % [sim.tick, world.entity_count()],
		# Read with defaults: a debug overlay must never be able to stop the
		# game, and a missing counter is not worth an exception every frame.
		"belts %d   items on belts %d" % [_stat("belts"), _stat("belt_items")],
		"mined %d   crafts %d" % [_stat("mined"), _stat("crafts")],
		"power %.0f kW / %.0f kW demand" % [
			sim.power.total_generation / 1000.0, sim.power.total_demand / 1000.0],
		_character_line(),
		_items_line(),
		_wire_line(),
		_research_line(),
		_alerts_line(),
		_health_line(),
		_enemy_line(),
		_save_line(),
	])


## One of the simulation's rolling counters, or zero if it is not there.
func _stat(key: String) -> int:
	if sim == null:
		return 0
	var counters: Variant = sim.stats
	if not (counters is Dictionary):
		return 0
	return int((counters as Dictionary).get(key, 0))


## The engineer's health line, shown whenever they are hurt or healing.
func _health_line() -> String:
	if character == null:
		return ""
	var bar_width := 20
	var filled := int(round(character.health_fraction() * bar_width))
	var bar := "%s%s" % ["|".repeat(filled), ".".repeat(maxi(0, bar_width - filled))]
	var line := "health: [%s] %.0f/%.0f" % [bar, character.health, character.max_health]
	# A hit marks the line for a moment, standing in for the screen tint.
	if _damage_flash > 0.0:
		line = "!! " + line
	var gun := player.selected_gun() if player != null else ""
	if not gun.is_empty():
		var ammo := player.ammo_for(gun)
		line += "   %s%s" % [Loc.proto_name("gun", gun),
			" x%d" % player.inventory.count_of(ammo) if not ammo.is_empty() else " (no ammo)"]
	return line


func _on_health_changed(_health: float, _max_health: float) -> void:
	_hud_dirty = true


## Factorio respawns the engineer at the spawn point; the inventory is left on
## the corpse, which is not modelled yet, so only the position resets.
func _on_engineer_died() -> void:
	print("the engineer was killed at tick %d" % sim.tick)
	character.respawn(Vector2(_spawn_cell) + Vector2(0.5, 0.5))
	camera.position = character.world_position()
	camera.follow_target = character.world_position()
	_ensure_character_free()
	_damage_flash = 1.0


func _alerts_line() -> String:
	if sim.alerts == null or sim.alerts.total() == 0:
		return ""
	var parts := PackedStringArray()
	for entry: Dictionary in sim.alerts.grouped():
		var kind := str(entry["kind"])
		parts.append("%s x%d" % [str(Alerts.TITLES.get(kind, kind)),
			int(entry["count"])])
	return "alerts: %s" % ", ".join(parts)


func _enemy_line() -> String:
	var smog := sim.pollution.stats()
	var line := "pollution: %.0f in %d chunks (worst %.0f)   evolution %.1f%%" % [
		float(smog["total"]), int(smog["chunks"]), float(smog["worst"]),
		sim.evolution * 100.0]
	if not sim.units.is_empty():
		line += "   biters: %d" % sim.units.size()
	if int(sim.stats.get("units_killed", 0)) > 0:
		line += " (killed %d)" % int(sim.stats["units_killed"])
	return line


func _save_line() -> String:
	if _save_flash <= 0.0:
		return ""
	return "F5 saved / F9 loaded"


## A nest and a turret, so the biters have somewhere to come from and
## something to run into.
func _build_enemy_demo() -> void:
	var nest_cell := _free_cell_near(_spawn_cell + Vector2i(24, 0))
	for i in 3:
		var cell := nest_cell + Vector2i(i * 5, (i % 2) * 5)
		world.place_entity(Entity.create("unit-spawner", "biter-spawner", cell, 0))
	# A turret watching the line, with a magazine.
	var turret_cell := _free_cell_near(_spawn_cell + Vector2i(-6, 6))
	var turret := Entity.create("ammo-turret", "gun-turret", turret_cell, 0)
	world.place_entity(turret)
	InventoryLayout.get_inventory(turret, InventoryLayout.FUEL).insert(
		"firearm-magazine", 20)
	# Give the nest something to smell.
	for i in 40:
		sim.pollution.add(nest_cell, 900.0)
	sim.fluids.mark_dirty()
	sim.mark_power_dirty()
	print("enemy demo: %d nests, turret at %s" % [
		world.entities_of_type("unit-spawner").size(), turret_cell])


## The in-game menu over a working factory, for the UI dump.
func _pause_demo() -> void:
	# The pause menu sits over the game, not over the title screen.
	main_menu.close_menu()
	pause_menu.open_menu()


## A handful of broken machines, so the alert panel has something to show.
func _build_alert_demo() -> void:
	var base := _free_cell_near(_spawn_cell + Vector2i(0, 8))
	# A furnace with ore and no coal.
	var furnace := Entity.create("furnace", "stone-furnace", base, 0)
	if world.place_entity(furnace):
		InventoryLayout.get_inventory(furnace, InventoryLayout.INPUT).insert(
			"iron-ore", 20)
	# An empty turret.
	world.place_entity(Entity.create("ammo-turret", "gun-turret",
		base + Vector2i(5, 0), 0))
	# An electric drill with no power.
	world.place_entity(Entity.create("mining-drill", "electric-mining-drill",
		base + Vector2i(10, 0), 0))
	# A chemical plant with a recipe and no water.
	var plant := Entity.create("assembling-machine", "chemical-plant",
		base + Vector2i(0, 6), 0)
	if world.place_entity(plant):
		plant.state["recipe"] = "sulfuric-acid"
		InventoryLayout.get_inventory(plant, InventoryLayout.INPUT).insert(
			"sulfur", 20)
		InventoryLayout.get_inventory(plant, InventoryLayout.INPUT).insert(
			"iron-plate", 20)
	# A biter, for the danger icon.
	sim.spawn_unit("small-biter", base + Vector2i(14, 2))
	sim.character = character
	# Let the slow scan run.
	for i in Alerts.SCAN_TICKS + 2:
		sim.step()
	alert_panel.refresh()
	print("alert demo: %d alerts" % sim.alerts.total())


## Drop an assembling machine in a free spot near the engineer, for the UI
## dumps that need one.
func _spawn_assembler() -> Entity:
	var base := _free_cell_near(_spawn_cell + Vector2i(0, 4))
	if base == Vector2i.ZERO and world.entity_at(Vector2i.ZERO) != null:
		return null
	var machine := Entity.create("assembling-machine", "assembling-machine-1", base, 0)
	if not world.place_entity(machine):
		return null
	world.place_entity(Entity.create("electric-pole", "small-electric-pole",
		base + Vector2i(4, 0), 0))
	world.place_entity(Entity.create("solar-panel", "solar-panel",
		base + Vector2i(6, -1), 0))
	sim.mark_power_dirty()
	return machine


func _research_line() -> String:
	if research == null:
		return ""
	if research.current.is_empty():
		return "research: idle   %d/%d technologies" % [
			research.researched.size(), research.technologies.size()]
	return "research: %s %.0f%%   (%d labs)" % [
		Loc.proto_name("technology", research.current), research.progress() * 100.0,
		world.entities_of_type("lab").size()]


func _character_line() -> String:
	if character == null:
		return ""
	var state := "standing"
	if character.animation == "running":
		state = "running"
	elif not character.mining_target.is_empty():
		state = "mining %s (%.0f%%)" % [
			str(character.mining_target.get("name", "")),
			character.mining_progress * 100.0]
	return "engineer at %.1f, %.1f   %s" % [
		character.position.x, character.position.y, state]


## The wire tool has no window of its own, so its state lives in the HUD.
func _wire_line() -> String:
	if player == null or player.wire_colour.is_empty():
		return ""
	return "wire: %s   Ctrl+W cycles / puts it away" % player.wire_colour


func _items_line() -> String:
	if player == null:
		return ""
	var types := 0
	for slot: Variant in player.inventory.slots:
		if slot != null:
			types += 1
	return "carrying %d stacks   hand crafting %d" % [types, player.craft_queue.size()]


# --------------------------------------------------------------------------
# offline draw dump
# --------------------------------------------------------------------------

## Write the renderer's draw list to disk so the offline preview tool can
## composite it without a GPU.  Verifies the sprite slicing end to end.
func _dump_draw_list() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var view_size := viewport_size / _dump_zoom
	var view := Rect2(camera.position - view_size * 0.5, view_size)
	DirAccess.make_dir_recursive_absolute("res://tmp_preview/icon_cache")

	var records: Array = []
	var icon_paths: Dictionary = {}
	for item: Dictionary in renderer.build_draw_list(view):
		var src: Rect2 = item["src"]
		var dest: Rect2 = item["dest"]
		var modulate: Color = item["modulate"]
		var path := str(item["path"])
		if path.is_empty():
			# A wire has no texture at all — it is a line, and the offline
			# compositor draws it from the geometry.
			if item.has("line"):
				records.append({
					"path": "",
					"line": item["line"],
					"src": [0, 0, 0, 0],
					"dest": [dest.position.x, dest.position.y,
						dest.size.x, dest.size.y],
					"modulate": [modulate.r, modulate.g, modulate.b, modulate.a],
				})
				continue
			# Composed textures (item icons) have no source file, so park them
			# in the preview folder for the offline compositor to read.
			var texture: Texture2D = item["texture"]
			if texture == null:
				continue
			# Keyed by the texture itself, not by its size: every composed
			# icon is 64x64, so a size-based key made them all the same file
			# and every belt item and ALT badge drew the first one written.
			var key := "tex%s" % texture.get_instance_id()
			if not icon_paths.has(key):
				var icon_file := "res://tmp_preview/icon_cache/%s.png" % key
				texture.get_image().save_png(icon_file)
				icon_paths[key] = icon_file
			path = icon_paths[key]
		records.append({
			"path": path,
			"rotation": float(item.get("rotation", 0.0)),
			"src": [src.position.x, src.position.y, src.size.x, src.size.y],
			"dest": [dest.position.x, dest.position.y, dest.size.x, dest.size.y],
			"modulate": [modulate.r, modulate.g, modulate.b, modulate.a],
		})
	# The night is an overlay rather than a world item, so it travels with the
	# dump for the offline compositor to lay on top.
	var night := sim.day.tint() if sim != null and sim.day != null \
		else Color(1, 1, 1, 0)
	var payload := {
		"view": [view.position.x, view.position.y, view.size.x, view.size.y],
		"zoom": _dump_zoom,
		"night": [night.r, night.g, night.b, night.a],
		"items": records,
	}
	var file := FileAccess.open(_dump_path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write draw dump to " + _dump_path)
		return
	file.store_string(JSON.stringify(payload))
	file.close()
	print("draw dump: %d items -> %s" % [records.size(), _dump_path])


# --------------------------------------------------------------------------
# screenshot mode
# --------------------------------------------------------------------------

func _on_frame_post_draw() -> void:
	if _capturing or _frame_counter < _screenshot_after:
		return
	_capturing = true
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(_screenshot_path)
	if error != OK:
		push_error("could not write screenshot: %d" % error)
	else:
		print("screenshot written to ", _screenshot_path)
	get_tree().quit(0)


# --------------------------------------------------------------------------
# offline UI dump
# --------------------------------------------------------------------------

## Lay out one of the windows and write every control it contains to JSON, so
## ``tools/preview_ui.py`` can render the interface without a GPU.
func _dump_ui_tree() -> void:
	var target: Entity = null
	inventory_window.close_window()
	entity_window.close_window()
	research_window.close_window()
	match _dump_ui_screen:
		"entity":
			target = _first_machine()
			if not sim.trains.trains.is_empty():
				# The train showroom: open the locomotive's window, which is
				# where a schedule is written.
				var train: Dictionary = sim.trains.trains[0]
				train["schedule"] = ["Iron ore", "Smelting"]
				train["schedule_index"] = 1
				entity_window.open_train(train)
			elif target != null:
				entity_window.open_window(target)
			else:
				push_warning("no machine found to show")
		"picker":
			# Research the tree far enough that an assembling machine exists,
			# then put one down with its recipe list open.
			research.on_item_produced("iron-plate", 50)
			research.on_item_produced("copper-plate", 10)
			research.on_item_produced("lab", 1)
			research.researched["automation"] = true
			research.rebuild_unlocks()
			var assembler := _spawn_assembler()
			if assembler != null:
				entity_window.open_window(assembler)
				entity_window._open_picker()
			else:
				push_warning("no room for an assembling machine")
		"mainmenu":
			main_menu.open(true, "Factorio 2.0.77 data")
		"pause":
			_pause_demo()
		"objectives":
			# Walk the chain until something is unmet, then show that one.
			for i in 3:
				objectives.update()
			objective_panel.refresh()
		"map":
			map_window.visible = true
			map_window.size = get_viewport().get_visible_rect().size
			map_window.build_colours()
			map_window.centre_on(_spawn_cell)
		"victory":
			victory_screen.announce(1, 42.5)
		"equipment":
			# Wear a suit and fit it out, so the grid has something to show.
			if player.inventory.count_of("power-armor-mk2") == 0:
				player.inventory.insert("power-armor-mk2", 1)
			player.equip_armor("power-armor-mk2")
			for piece: String in ["fusion-reactor-equipment",
					"energy-shield-mk2-equipment", "exoskeleton-equipment",
					"personal-roboport-equipment", "battery-mk2-equipment",
					"night-vision-equipment"]:
				if player.inventory.count_of(piece) == 0:
					player.inventory.insert(piece, 1)
				player.fit_equipment(piece)
			player.quickbar[0] = "energy-shield-equipment"
			player.selected_slot = 0
			equipment_window.open_window()
		"production":
			production_window.open_window()
		"tooltip":
			tooltips.preview_card(Tooltips.item_card("assembling-machine-1"),
				Vector2(560, 460))
		"recipe-tooltip":
			tooltips.preview_card(Tooltips.recipe_card("electronic-circuit"),
				Vector2(560, 460))
		"alerts":
			_build_alert_demo()
			alert_panel.refresh()
		"research":
			# Give the tree something to show.
			research.on_item_produced("iron-plate", 50)
			research.on_item_produced("copper-plate", 10)
			research.on_item_produced("lab", 1)
			research_window.open_window()
			# Start the tree at its roots for the picture.
			if research_window._scroll != null:
				research_window._scroll.scroll_horizontal = 0
				research_window._scroll.scroll_vertical = 0
		_:
			inventory_window.open_window()

	# Containers only know their final rects after a layout pass.
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	DirAccess.make_dir_recursive_absolute("res://tmp_preview/icon_cache")
	var records: Array = []
	var icons := _collect_controls(ui_root, records)
	# The HUD lives on its own layer, and the objective panel on it is part of
	# what the picture should show.
	if hud != null:
			_collect_controls(hud, records)
	var payload := {
		"viewport": [get_viewport().get_visible_rect().size.x,
			get_viewport().get_visible_rect().size.y],
		"screen": _dump_ui_screen,
		"icons": icons,
		"controls": records,
	}
	var file := FileAccess.open(_dump_ui_path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write UI dump to " + _dump_ui_path)
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(payload))
	file.close()
	print("ui dump: %d controls -> %s" % [records.size(), _dump_ui_path])
	get_tree().quit(0)


func _first_machine() -> Entity:
	for candidate: String in ["furnace", "assembling-machine", "container", "mining-drill"]:
		var found: Array = world.entities_of_type(candidate)
		if not found.is_empty():
			return found[0]
	return null


func _collect_controls(node: Node, out: Array) -> Dictionary:
	var icons: Dictionary = {}
	# A hidden window hides its whole subtree.
	if node is CanvasItem and not (node as CanvasItem).visible:
		return icons
	if node is Control:
		var control := node as Control
		if control.size.x >= 1.0 and control.size.y >= 1.0:
			out.append(_describe_control(control, icons))
	for child in node.get_children():
		var nested := _collect_controls(child, out)
		for key: String in nested:
			icons[key] = nested[key]
	return icons


func _describe_control(control: Control, icons: Dictionary) -> Dictionary:
	var rect := control.get_global_rect()
	var entry := {
		"type": control.get_class(),
		"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
		"style": str(control.get_meta("factorio_style", "")),
		"text": "",
		"font_size": 14,
		"color": [1, 1, 1, 1],
		"align": "left",
		"texture": "",
		"region": [],
		"margins": [0, 0, 0, 0],
		"modulate": [control.modulate.r, control.modulate.g, control.modulate.b,
			control.modulate.a],
		"clip": [],
	}

	# Record the visible region so the offline renderer can clip the same way.
	var clip := Rect2()
	var ancestor := control.get_parent()
	while ancestor != null:
		if ancestor is Control and (ancestor as Control).clip_contents:
			var box := (ancestor as Control).get_global_rect()
			clip = box if clip.size == Vector2.ZERO else clip.intersection(box)
		ancestor = ancestor.get_parent()
	if clip.size.x > 0.0 and clip.size.y > 0.0:
		entry["clip"] = [clip.position.x, clip.position.y, clip.size.x, clip.size.y]

	if control is Button:
		entry["text"] = (control as Button).text
		entry["align"] = "center"
		entry["valign"] = "center"
	if control is LineEdit:
		var field := control as LineEdit
		entry["text"] = field.text if not field.text.is_empty() else field.placeholder_text
		entry["color"] = [0.62, 0.62, 0.62, 1.0] if field.text.is_empty() else [0.9, 0.9, 0.9, 1.0]
		entry["valign"] = "center"

	if control is Label:
		var label := control as Label
		entry["text"] = label.text
		entry["font_size"] = label.get_theme_font_size("font_size")
		var colour := label.get_theme_color("font_color")
		entry["color"] = [colour.r, colour.g, colour.b, colour.a]
		entry["align"] = "center" if label.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER 			else ("right" if label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT else "left")
		entry["valign"] = "bottom" if label.vertical_alignment == VERTICAL_ALIGNMENT_BOTTOM 			else ("center" if label.vertical_alignment == VERTICAL_ALIGNMENT_CENTER else "top")

	if control is TextureRect:
		var texture_rect := control as TextureRect
		# An icon is a small square drawn inside a slot; a picture is a whole
		# surface that fills its control, like the map.
		var big := texture_rect.texture != null \
			and texture_rect.texture.get_width() > 96
		entry["texture_kind"] = "picture" if big else "icon"
		if texture_rect.texture != null:
			# Icons are composed at runtime and all come out the same size, so
			# they are named after the item they belong to.
			var key := str(control.get_meta("factorio_icon", ""))
			if key.is_empty():
				key = "tex%d" % texture_rect.texture.get_instance_id()
			if not icons.has(key):
				var path := "res://tmp_preview/icon_cache/%s.png" % key
				texture_rect.texture.get_image().save_png(path)
				icons[key] = path
			entry["texture"] = icons[key]

	# A control that draws itself can hand its geometry over, because a
	# picture of a _draw call cannot be taken from the control list alone.
	if control.has_method("overlay_lines"):
		var overlay: Variant = control.call("overlay_lines")
		if overlay is Array and not (overlay as Array).is_empty():
			entry["overlay"] = overlay

	# The 9-slice, if this control has one.
	for property_name: String in ["panel", "normal", "hover", "pressed"]:
		var box := control.get_theme_stylebox(property_name)
		if box is StyleBoxTexture:
			var texture_box := box as StyleBoxTexture
			entry["texture"] = FactorioStyle.path_for(texture_box.texture)
			var region := texture_box.region_rect
			entry["region"] = [region.position.x, region.position.y, region.size.x, region.size.y]
			entry["margins"] = [texture_box.texture_margin_left, texture_box.texture_margin_top,
				texture_box.texture_margin_right, texture_box.texture_margin_bottom]
			entry["sheet_scale"] = FactorioStyle.sprite_scale
			break

	if control is ProgressBar:
		var bar := control as ProgressBar
		entry["value"] = bar.value / maxf(bar.max_value, 0.001)
	return entry
