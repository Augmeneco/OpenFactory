class_name WorldRenderer
extends Node2D
## Draws terrain, ore and entities in one batched pass.
##
## Everything is emitted as textured rectangles from a single ``_draw``
## override rather than one node per tile, which is what makes a
## Factorio-sized factory affordable.  The same list is reused by the offline
## preview tool, so what you see in a screenshot is exactly what the game
## would blit.

const TILE := 32.0

## Water animation speed in frames per second.
const WATER_FPS := 6.0

## Drawn size of an item riding a belt, in pixels.
const ITEM_ICON_PIXELS := 11.0

## Opacity multiplier applied to shadow sprites.
const SHADOW_ALPHA := 0.35

var world: GameWorld
## Optional: needed to draw the biters, which live outside the entity table.
var simulation: Simulation
## The player's engineer, drawn with the entities so it sorts by depth.
var character: Character
var show_grid := false
var show_ore := true
## Factorio's ALT mode: a badge over every machine showing what it is making,
## which chest it is, or what ore is under a drill.
var show_alt := false
## Camera scale (viewport pixels per world pixel) at or below which terrain is
## drawn from cached simplified chunks instead of individual tile sprites.
var ground_lod_threshold := 0.70
## When true, only chunks the game has generated are drawn.  Remote view and
## the normal camera then cannot reveal terrain without a radar/player loader.
var require_generated_chunks := false
## The satellite/remote view only draws chunks the player or a radar scanned.
var require_revealed_chunks := false

var _anim_time := 0.0
var _item_icons: Dictionary = {}
## Soft dark halo drawn behind an ALT-mode icon so the icon stays readable
## over the busy machine artwork.
var _alt_backdrop: Texture2D
## Current view scale (viewport pixels per world pixel).  Below the LOD
## thresholds the renderer swaps per-tile ground for cached chunk pictures and
## drops tiny decorations, so zooming out cannot turn a 144-chunk view into
## 150k textured cells.
## Machine types whose base sprite should only advance while producing.
const FACTORY_TYPES := [
	"furnace", "assembling-machine", "mining-drill", "boiler", "generator",
	"rocket-silo", "lab", "offshore-pump",
]

var _render_scale := 1.0
var _map_chunks: MapChunks
## Monotonic counter that keeps layers of one entity in their sheet order.
var _sequence := 0


func _process(delta: float) -> void:
	_anim_time += delta
	queue_redraw()


## The night, laid over everything the world draws and under the interface.
##
## A night-vision unit on the engineer stops it, which is the whole of what
## that equipment does.
func _draw() -> void:
	for item: Dictionary in build_draw_list(visible_world_rect()):
		if item.has("line"):
			var line: Array = item["line"]
			var line_colour := Color(float(line[4]), float(line[5]), float(line[6]),
				float(item.get("line_alpha", 1.0)))
			draw_line(Vector2(float(line[0]), float(line[1])),
				Vector2(float(line[2]), float(line[3])), line_colour,
				maxf(1.0, float(item.get("width", 2.0))))
			continue
		var texture: Texture2D = item["texture"]
		if texture == null:
			continue
		var spin := float(item.get("rotation", 0.0))
		if is_zero_approx(spin):
			draw_texture_rect_region(texture, item["dest"], item["src"],
				item["modulate"])
			continue
		# Turned about its pivot (the middle of the rectangle by default, the
		# inserter base for an arm), then put the transform back so the next
		# sprite is not affected.
		var dest: Rect2 = item["dest"]
		var pivot: Vector2 = item.get("pivot", dest.get_center())
		draw_set_transform(pivot, spin, Vector2.ONE)
		draw_texture_rect_region(texture,
			Rect2(dest.position - pivot, dest.size), item["src"], item["modulate"])
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## World-space rectangle currently visible through the canvas transform.
func visible_world_rect() -> Rect2:
	var inverse := get_viewport().get_canvas_transform().affine_inverse()
	var size := get_viewport_rect().size
	var a := inverse * Vector2.ZERO
	var b := inverse * size
	return Rect2(a, b - a).abs()


# --------------------------------------------------------------------------
# draw list construction
# --------------------------------------------------------------------------

## Every textured rectangle that covers ``view``, in painting order.
func build_draw_list(view: Rect2) -> Array:
	var out: Array = []
	_render_scale = _view_scale(view)
	var min_cell := Vector2i(
		int(floor(view.position.x / TILE)) - 1,
		int(floor(view.position.y / TILE)) - 1)
	var max_cell := Vector2i(
		int(ceil(view.end.x / TILE)) + 1,
		int(ceil(view.end.y / TILE)) + 1)

	if _render_scale <= ground_lod_threshold:
		_emit_ground_lod(out, min_cell, max_cell)
	else:
		_emit_ground(out, min_cell, max_cell)
	_emit_entities(out, min_cell, max_cell)
	if show_grid:
		_emit_grid(out, min_cell, max_cell)
	return out


# --------------------------------------------------------------------------
# ground cache
# --------------------------------------------------------------------------

## One cell's terrain and ore rectangles, resolved lazily.
##
## Rebuilding these every frame was the largest cost in an otherwise empty
## world: about 1,700 terrain cells plus a few hundred ore cells were looked up
## through the chunk dictionary, the tile atlas and the resource prototypes on
## every single frame.  Ground only changes when the world does, or when the
## water animation steps, so the prepared lists are kept and reused.
var _cell_cache: Dictionary = {}
var _cell_cache_revision := -1
var _cell_cache_water_frame := -1
var _cell_cache_show_ore := true


func _emit_ground(out: Array, min_cell: Vector2i, max_cell: Vector2i) -> void:
	var water_frame := int(_anim_time * WATER_FPS)
	if _cell_cache_revision != world.revision \
			or _cell_cache_water_frame != water_frame \
			or _cell_cache_show_ore != show_ore:
		_cell_cache.clear()
		_cell_cache_revision = world.revision
		_cell_cache_water_frame = water_frame
		_cell_cache_show_ore = show_ore
	# A long journey would otherwise keep every cell ever seen alive.
	if _cell_cache.size() > 60000:
		_cell_cache.clear()
	for cy in range(min_cell.y, max_cell.y + 1):
		for cx in range(min_cell.x, max_cell.x + 1):
			var cell := Vector2i(cx, cy)
			if not _chunk_loaded(cell):
				continue
			var cached: Variant = _cell_cache.get(cell)
			if cached == null:
				cached = _build_cell(cell)
				_cell_cache[cell] = cached
			if not (cached as Array).is_empty():
				out.append_array(cached)


## Viewport pixels per world pixel, clamped so a detached preview still works.
func _view_scale(view: Rect2) -> float:
	if view.size.x <= 0.0:
		return 1.0
	var viewport_width := float(get_viewport_rect().size.x)
	if viewport_width <= 0.0:
		return 1.0
	return clampf(viewport_width / view.size.x, 0.01, 8.0)


## Zoomed-out ground: one cached 32x32 coloured chunk texture per chunk.
## Ungenerated chunks are left dark rather than generating hundreds of them
## inside a single frame.
func _emit_ground_lod(out: Array, min_cell: Vector2i, max_cell: Vector2i) -> void:
	if _map_chunks == null:
		_map_chunks = MapChunks.new(world)
	_map_chunks.require_generated = require_generated_chunks
	_map_chunks.require_revealed = require_revealed_chunks
	var first := GameWorld.chunk_of(min_cell)
	var last := GameWorld.chunk_of(max_cell)
	for cy in range(first.y, last.y + 1):
		for cx in range(first.x, last.x + 1):
			var coord := Vector2i(cx, cy)
			var texture := _map_chunks.texture_for(coord, false, true)
			if texture == null:
				continue
			out.append({
				"texture": texture,
				"path": "",
				"src": Rect2(0, 0, GameWorld.CHUNK, GameWorld.CHUNK),
				"dest": Rect2(Vector2(coord * GameWorld.CHUNK) * TILE,
					Vector2(GameWorld.CHUNK, GameWorld.CHUNK) * TILE),
				"modulate": Color.WHITE,
				"sort_y": 0.0,
			})


## The terrain (and ore) rectangles standing on one cell.
func _build_cell(cell: Vector2i) -> Array:
	var out: Array = []
	var tile := world.tile_at(cell)
	var info := TileAtlas.render_info(tile)
	if not info.is_empty():
		var rects: Array = info["rects"]
		var frames: int = info["frames"]
		var src: Rect2
		if frames > 1:
			src = rects[int(_anim_time * WATER_FPS) % frames]
		else:
			src = rects[TileAtlas.variant_index(info, cell)]
		_push(out, info["path"], src,
			Rect2(float(cell.x) * TILE, float(cell.y) * TILE, TILE, TILE),
			Color.WHITE, 0.0, info["texture"])
	if not show_ore:
		return out
	var ore := world.ore_at(cell)
	var ore_name: String = ore["name"]
	if ore_name.is_empty():
		return out
	var entry := _ore_visual(ore_name)
	if entry.is_empty():
		return out
	var stages: Variant = entry["stages"]
	var variation := SpriteSource.variation_for(cell, int(entry["variations"]))
	var stage := world.generator.ore_stage(ore_name, ore["amount"])
	# A stable tag is essential: without it SpriteCache builds a structural
	# fingerprint of the whole `stages` subtree for every ore tile, which made
	# the overlay the single most expensive part of the frame.
	var layers: Array = SpriteCache.layers(stages, 0, stage, variation,
		"ore/%s" % ore_name)
	var centre := (Vector2(cell) + Vector2(0.5, 0.5)) * TILE
	for layer: SpriteSource.Layer in layers:
		_push(out, layer.reference, layer.src_rect,
			Rect2(centre + layer.offset - layer.size * 0.5, layer.size),
			layer.modulate)
	return out


## Per-resource artwork lookup, resolved once per ore kind.
var _ore_visuals: Dictionary = {}


func _ore_visual(ore_name: String) -> Dictionary:
	var cached: Variant = _ore_visuals.get(ore_name)
	if cached != null:
		return cached
	var proto := Prototypes.get_p("resource", ore_name)
	if proto.is_empty():
		_ore_visuals[ore_name] = {}
		return {}
	var built := {
		"stages": proto.get("stages", {}),
		"variations": _resource_variations(proto),
	}
	_ore_visuals[ore_name] = built
	return built


func _push(out: Array, path: String, src: Rect2, dest: Rect2,
		modulate: Color = Color.WHITE, sort_y := 0.0,
		texture_override: Texture2D = null) -> void:
	out.append({
		"texture": texture_override if texture_override != null else FactorioAssets.texture(path),
		"path": path,
		"src": src,
		"dest": dest,
		"modulate": modulate,
		"sort_y": sort_y,
	})


# --------------------------------------------------------------------------
# ore
# --------------------------------------------------------------------------

func _resource_variations(proto: Dictionary) -> int:
	var sheet: Variant = proto.get("stages", {}).get("sheet", {})
	if sheet is Dictionary:
		return maxi(1, int(sheet.get("variation_count", 1)))
	return 1


# --------------------------------------------------------------------------
# entities
# --------------------------------------------------------------------------

func _chunk_loaded(cell: Vector2i) -> bool:
	if world == null:
		return true
	var coord := GameWorld.chunk_of(cell)
	if require_generated_chunks and not world.is_generated(coord):
		return false
	if require_revealed_chunks and not world.is_chunk_revealed(coord):
		return false
	return true


func _emit_entities(out: Array, min_cell: Vector2i, max_cell: Vector2i) -> void:
	var shadows: Array = []
	var bodies: Array = []
	var badges: Array = []
	_sequence = 0

	for entity: Entity in world.entities.values():
		if not _chunk_loaded(entity.origin):
			continue
		if entity.origin.x + entity.size.x < min_cell.x or entity.origin.x > max_cell.x:
			continue
		if entity.origin.y + entity.size.y < min_cell.y or entity.origin.y > max_cell.y:
			continue
		if _render_scale < 0.65 and entity.proto_type in [
				"tree", "simple-entity", "item-entity"]:
			continue
		if _render_scale < 0.22 and entity.proto_type in [
				"inserter", "electric-pole", "big-electric-pole", "substation",
				"pipe", "pipe-to-ground", "wall", "gate", "item-entity"]:
			continue
		var center := entity.center() * TILE
		if entity.proto_type == "item-entity":
			_emit_ground_item(bodies, entity, center)
			continue
		if not entity.is_ghost() and _needs_power_badge(entity):
			_emit_power_badge(badges, entity, center)
		var visual_data := EntityVisuals.visual(entity, 0, world)
		if visual_data.is_empty():
			continue
		if entity.proto_type == "tree" and simulation != null:
			# Tree sheets use three frames for leaf density (pollution/damage
			# stages), not for playback.  Pick a stable stage instead of the
			# generic animation clock.
			visual_data["frame"] = _tree_stage(entity)
		elif entity.proto_type == "simple-entity":
			# Rocks are static decorations.  Their `pictures` entries are
			# variants, not animation frames; never walk the global clock.
			visual_data["frame"] = 0
		elif entity.proto_type in FACTORY_TYPES \
				and not _machine_is_working(entity):
			# Factories only animate while they are actually producing.  An
			# idle furnace, assembler, boiler or turbine freezes on its first
			# frame instead of spinning silently.
			visual_data["frame"] = 0
		var direction := int(visual_data["direction"])
		var spin := float(visual_data.get("rotation", 0.0))
		var any := false
		var as_row := bool(visual_data.get("is_row", false))
		var node_offsets: Array = visual_data.get("offsets", [])
		var node_index := 0
		var nodes: Array = visual_data["nodes"]
		if visual_data.has("working_nodes") and _machine_is_working(entity):
			nodes = nodes.duplicate()
			nodes.append_array(visual_data["working_nodes"])
		for graphics: Variant in nodes:
			# The visual may have already resolved a direction table and
			# returned direction 0 (drills do this).  The tag must include the
			# entity's facing or the first orientation's sprite stays cached
			# for every rotation.
			# Include the tile: variation is chosen per entity in
			# EntityVisuals, so two rocks with the same prototype must not
			# share one cached variant (the first rock otherwise painted all
			# the others and appeared to change when the cache was rebuilt).
			# Pipes select one of eighteen connection pictures from their
			# neighbours.  The picture is part of the cache identity; without
			# it a pipe could keep the sprite it had before a neighbouring
			# pipe/machine changed its port and appear to switch at random
			# when another pipe was cached/reloaded.
			var shape_tag := ""
			if entity.proto_type == "pipe":
				shape_tag = "/" + EntityVisuals.pipe_picture_key(world, entity)
			var tag := "%s/%s/d%d/o%d_%d%s#%d" % [entity.proto_type,
				entity.name, posmod(entity.direction, 16), entity.origin.x,
				entity.origin.y, shape_tag, node_index]
			# A multi-tile entity such as a splitter draws one node per tile.
			var tile_shift := Vector2.ZERO
			if node_index < node_offsets.size():
				tile_shift = Vector2(node_offsets[node_index]) * TILE
			node_index += 1
			var variation := EntityVisuals.variation_for(entity, _variation_count(graphics))
			# Belts scroll their sheet; the frame is derived from the belt's
			# own speed so yellow, red and blue belts do not animate alike.
			var frame := _belt_animation_frame(entity, graphics) if as_row \
				else _entity_animation_frame()
			if visual_data.has("frame"):
				frame = int(visual_data["frame"])
			var layers: Array = SpriteCache.layers_row(graphics, direction, frame,
				variation, tag) if as_row else SpriteCache.layers(graphics,
				direction, frame, variation, tag)
			for layer: SpriteSource.Layer in layers:
				# These are additive light masks: the batched canvas cannot
				# blend them, and drawing one normally paints an opaque black
				# rectangle over the machine (the furnace looked textureless
				# while smelting).
				if layer.light or layer.additive:
					continue
				any = true
				var dest := Rect2(center + tile_shift + layer.offset - layer.size * 0.5,
					layer.size)
				var modulate := layer.modulate
				if layer.shadow:
					# Factorio renders shadows in a separate, softened pass;
					# the raw sprites are pure black and would read as holes.
					modulate.a *= SHADOW_ALPHA
				if entity.is_ghost():
					# A ghost is a plan, so it is drawn faint and blue.
					modulate = modulate * Color(0.45, 0.6, 1.0, 0.45)
				# Depth is the entity's, not the layer's: sorting layers
				# individually would let a mask draw before the sprite it
				# belongs to.  ``seq`` keeps the layers in sheet order.
				var item := {
					"texture": layer.texture,
					"path": layer.reference,
					"src": layer.src_rect,
					"dest": dest,
					"modulate": modulate,
					"rotation": spin + layer.rotation,
					"sort_y": center.y,
					"seq": _sequence,
				}
				_sequence += 1
				if layer.shadow:
					shadows.append(item)
				else:
					bodies.append(item)
		if entity.proto_type == "inserter":
			# Arms are drawn in the UI-like badge layer: Factorio keeps an
			# inserter's hand above belts, pipes and the machines in front of
			# it, even when the base itself is depth-sorted behind them.
			_emit_inserter_arm(badges, entity, center)
		if not any:
			continue

	if character != null:
		_emit_character(shadows, bodies)

	if show_alt:
		# ALT icons are UI, not world objects: they must sit above the machine
		# even when the badge is in the middle of a large multi-tile sprite.
		_emit_alt_badges(badges, min_cell, max_cell)
	_emit_wires(bodies, min_cell, max_cell)
	_emit_power_wires(bodies, min_cell, max_cell)

	_emit_units(shadows, bodies, min_cell, max_cell)
	_emit_robots(shadows, bodies, min_cell, max_cell)
	_emit_trains(shadows, bodies, min_cell, max_cell)
	_emit_belt_items(bodies, min_cell, max_cell)

	out.append_array(shadows)
	bodies.sort_custom(_sort_by_depth)
	out.append_array(bodies)
	# Badges are UI-ish and stay above every world object.
	out.append_array(badges)


## A stack of items lying on the ground, produced by a mining drill or dropped
## by a machine.  The real `item-on-ground` prototype has no picture of its
## own; the icon of the carried item is the picture.
func _emit_ground_item(bodies: Array, entity: Entity, centre: Vector2) -> void:
	var item_name := str(entity.state.get("item", ""))
	if item_name.is_empty():
		return
	var icon := _item_icon(item_name)
	if icon == null:
		return
	var size := Vector2(14, 14)
	bodies.append({
		"texture": icon,
		"path": "",
		"src": Rect2(Vector2.ZERO, Vector2(icon.get_width(), icon.get_height())),
		"dest": Rect2(centre - size * 0.5, size),
		"modulate": Color.WHITE,
		"sort_y": centre.y,
		"seq": _sequence,
	})
	_sequence += 1


## Electric consumers with no power at all get Factorio's unplugged alert.
func _needs_power_badge(entity: Entity) -> bool:
	if simulation == null or simulation.power == null:
		return false
	var proto := entity.prototype()
	if not Energy.is_electric(proto):
		return false
	if Energy.usage(proto) + Energy.drain(proto) <= 0.0:
		return false
	return simulation.power.satisfaction_for(entity) <= 0.001


var _power_alert_texture: Texture2D
var _power_alert_tried := false


func _emit_power_badge(badges: Array, entity: Entity, centre: Vector2) -> void:
	if not _power_alert_tried:
		_power_alert_tried = true
		_power_alert_texture = FactorioAssets.texture(
			"__core__/graphics/icons/alerts/electricity-icon-red.png")
	if _power_alert_texture == null:
		return
	var size := 20.0
	badges.append({
		"texture": _power_alert_texture,
		"path": "__core__/graphics/icons/alerts/electricity-icon-red.png",
		"src": Rect2(Vector2.ZERO,
			Vector2(_power_alert_texture.get_width(),
				_power_alert_texture.get_height())),
		"dest": Rect2(centre.x - size * 0.5,
			float(entity.origin.y) * TILE - size - 4.0, size, size),
		"modulate": Color(1, 0.9, 0.55, 1),
		"sort_y": centre.y + 100000.0,
		"seq": _sequence,
	})
	_sequence += 1


## Copper wires between power poles, drawn from their real connection points.
##
## PowerNetwork already decides which poles are in the same network by wire
## reach; drawing the same `links` list means the visual and the electrical
## topology can never disagree.
func _emit_power_wires(bodies: Array, min_cell: Vector2i, max_cell: Vector2i) -> void:
	if simulation == null or simulation.power == null:
		return
	var view := Rect2(Vector2(min_cell) * TILE,
		Vector2(max_cell - min_cell + Vector2i.ONE) * TILE).grow(TILE * 2.0)
	for link: Variant in simulation.power.connections():
		var a: Entity = link[0]
		var b: Entity = link[1]
		if not _chunk_loaded(a.origin) or not _chunk_loaded(b.origin):
			continue
		var from := PowerNetwork.wire_anchor(a)
		var to := PowerNetwork.wire_anchor(b)
		if not view.has_point(from) and not view.has_point(to):
			continue
		var points := PowerNetwork.wire_curve(from, to)
		var sort_y := maxf(a.center().y, b.center().y) * TILE + 4.0
		for i in points.size() - 1:
			var p1: Vector2 = points[i]
			var p2: Vector2 = points[i + 1]
			bodies.append({
				"texture": null,
				"path": "",
				"src": Rect2(),
				"dest": Rect2(p1, Vector2.ONE),
				"modulate": Color(0.82, 0.5, 0.22, 0.95),
				"sort_y": sort_y,
				"seq": _sequence,
				"line": [p1.x, p1.y, p2.x, p2.y, 0.82, 0.5, 0.22],
				"line_alpha": 0.95,
				"width": 1.5,
			})
			_sequence += 1

## Where a pole's copper wire is attached: its first `connection_points` entry.
func _pole_top(entity: Entity) -> Vector2:
	return PowerNetwork.wire_anchor(entity)

## Red and green wires, drawn as the lines they are.
##
## A wire is stored on both of the entities it joins, so only one end draws it:
## the one that comes first in reading order, or the line would be painted
## twice and come out too bright.
func _emit_wires(bodies: Array, min_cell: Vector2i, max_cell: Vector2i) -> void:
	if simulation == null or simulation.circuits == null:
		return
	for entity: Entity in world.entities.values():
		if entity.is_ghost():
			continue
		for wire: Variant in CircuitNetwork.wires_of(entity):
			if not (wire is Dictionary):
				continue
			var entry: Dictionary = wire
			var to: Variant = entry.get("to", null)
			if not (to is Array) or (to as Array).size() < 2:
				continue
			var other_cell := Vector2i(int((to as Array)[0]), int((to as Array)[1]))
			# Draw each wire once, from the lower coordinate.
			if other_cell.y < entity.origin.y:
				continue
			if other_cell.y == entity.origin.y and other_cell.x < entity.origin.x:
				continue
			var other := world.entity_at(other_cell)
			if other == null or not _chunk_loaded(other.origin):
				continue
			var colour := Color(0.85, 0.2, 0.2, 0.9) \
				if str(entry.get("colour", "red")) == "red" \
				else Color(0.3, 0.8, 0.3, 0.9)
			var from := entity.center() * TILE
			var target := other.center() * TILE
			bodies.append({
				"texture": null,
				"path": "",
				"src": Rect2(),
				"dest": Rect2(from, Vector2.ONE),
				"modulate": colour,
				# Wires lie on the ground, under everything standing on them.
				"sort_y": minf(from.y, target.y) - TILE * 4.0,
				"seq": _sequence,
				"line": [from.x, from.y, target.x, target.y, colour.r,
					colour.g, colour.b],
			})
			_sequence += 1


## The ALT-mode badges: one icon in the middle of each machine.
##
## Factorio draws the product a machine is set to make, the miner's ore, the
## logistic chest's role and a pipe's fluid.  The icon sits over the machine
## body with a soft dark halo behind it, rather than floating above the tile.
func _emit_alt_badges(badges: Array, min_cell: Vector2i,
		max_cell: Vector2i) -> void:
	const BADGE := 22.0
	const HALO := 52.0
	var halo := _alt_backdrop_texture()
	for entity: Entity in world.entities.values():
		if not _chunk_loaded(entity.origin):
			continue
		if entity.origin.x < min_cell.x or entity.origin.x > max_cell.x \
				or entity.origin.y < min_cell.y or entity.origin.y > max_cell.y:
			continue
		var icon := _alt_icon(entity)
		if icon == null:
			continue
		var centre := entity.center() * TILE
		if halo != null:
			badges.append({
				"texture": halo,
				"path": "",
				"src": Rect2(Vector2.ZERO, halo.get_size()),
				"dest": Rect2(centre - Vector2(HALO, HALO) * 0.5,
					Vector2(HALO, HALO)),
				"modulate": Color(1, 1, 1, 1),
				"sort_y": centre.y + 0.4,
				"seq": _sequence,
				"kind": "icon",
			})
			_sequence += 1
		badges.append({
			"texture": icon,
			"path": "",
			# A composed icon has no file; the whole texture is the source.
			"src": Rect2(Vector2.ZERO, icon.get_size()),
			"dest": Rect2(centre - Vector2(BADGE, BADGE) * 0.5,
				Vector2(BADGE, BADGE)),
			"modulate": Color(1, 1, 1, 1),
			# A hair in front of the machine it belongs to.
			"sort_y": centre.y + 0.5,
			"seq": _sequence,
			"kind": "icon",
		})
		_sequence += 1


## A radial darkening mask for ALT icons; fades out so the machine is still
## readable around the badge.
func _alt_backdrop_texture() -> Texture2D:
	if _alt_backdrop != null:
		return _alt_backdrop
	const SIZE := 64
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	var radius := float(SIZE) * 0.5
	for y in range(SIZE):
		for x in range(SIZE):
			var d := Vector2(float(x) + 0.5 - radius, float(y) + 0.5 - radius).length()
			var falloff := clampf(1.0 - d / radius, 0.0, 1.0)
			# Keep the centre dark but let it disappear completely at the edge.
			var alpha := pow(falloff, 1.5) * 0.58
			image.set_pixel(x, y, Color(0, 0, 0, alpha))
	_alt_backdrop = ImageTexture.create_from_image(image)
	return _alt_backdrop


## What the badge over one entity should show, or ``null`` for none.
func _alt_icon(entity: Entity) -> Texture2D:
	var proto := entity.prototype()
	# A machine shows what it makes.
	var recipe_name := str(entity.state.get("recipe", ""))
	if not recipe_name.is_empty():
		var products := Prototypes.recipe_products(
			Prototypes.get_p("recipe", recipe_name))
		if not products.is_empty():
			var first: Dictionary = products[0]
			var item := Prototypes.item_proto(str(first["name"]))
			if not item.is_empty():
				return FactorioAssets.prototype_icon(item, 64)
			return FactorioAssets.prototype_icon(
				Prototypes.get_p("fluid", str(first["name"])), 64)
	# A drill shows the ore under it.
	if entity.proto_type == "mining-drill" and simulation != null:
		var ore: Dictionary = simulation.has_ore_under(entity)
		if not ore.is_empty():
			return FactorioAssets.prototype_icon(
				Prototypes.get_p("resource", str(ore["name"])), 64)
	# A logistic chest shows which of the five it is.
	var mode := LogisticNetwork.mode_of(entity)
	if not mode.is_empty():
		return FactorioAssets.prototype_icon(proto, 64)
	return null


## Biters and spitters, drawn from their ``run_animation`` sheets.
##
## Units live off the tile grid, so they are keyed by their float position
## rather than by a cell.  Each layer of the animation is resolved separately
## because the mask layer has to ride on top of the body.
func _emit_units(shadows: Array, bodies: Array, min_cell: Vector2i,
		max_cell: Vector2i) -> void:
	if simulation == null:
		return
	for unit: Dictionary in simulation.units:
		# The unit's position is in tiles; everything drawn is in pixels.
		var position: Vector2 = Vector2(unit["position"]) * TILE
		var cell := Vector2i(int(floor(position.x / TILE)),
			int(floor(position.y / TILE)))
		if cell.x < min_cell.x - 2 or cell.x > max_cell.x + 2 \
				or cell.y < min_cell.y - 2 or cell.y > max_cell.y + 2:
			continue
		var proto: Dictionary = simulation.unit_prototype(unit)
		if proto.is_empty():
			continue
		var animation: Variant = proto.get("run_animation", {})
		var layers: Array = []
		if animation is Dictionary and animation.has("layers"):
			layers = animation["layers"]
		elif animation is Dictionary:
			layers = [animation]
		var direction := int(unit.get("direction", 8))
		var frame := int(unit.get("animation", 0.0)) % 16
		for index in layers.size():
			var node: Variant = layers[index]
			if not (node is Dictionary):
				continue
			var tag := "unit/%s#%d" % [str(unit["name"]), index]
			for layer: SpriteSource.Layer in SpriteCache.layers(
					node, direction, frame, 0, tag):
				var modulate := layer.modulate
				if layer.shadow:
					modulate.a *= SHADOW_ALPHA
				var item := {
					"texture": layer.texture,
					"path": layer.reference,
					"src": layer.src_rect,
					"dest": Rect2(position + layer.offset - layer.size * 0.5,
						layer.size),
					"modulate": modulate,
					"sort_y": position.y,
					"seq": _sequence,
				}
				_sequence += 1
				if layer.shadow:
					shadows.append(item)
				else:
					bodies.append(item)


## Trains, drawn carriage by carriage.
##
## A carriage's sprite is picked by its heading: the locomotive sheets hold 256
## rotations, so a 16-way direction is 16 rows into that circle.
func _emit_trains(shadows: Array, bodies: Array, min_cell: Vector2i,
		max_cell: Vector2i) -> void:
	if simulation == null or simulation.trains == null:
		return
	for train: Dictionary in simulation.trains.trains:
		var carriages: Array = train["carriages"]
		# A train running backwards is drawn nose-first the other way, which is
		# what its sprite has to be turned to.
		var direction := posmod(int(train["direction"]), 16)
		if float(train.get("speed", 0.0)) < 0.0:
			direction = posmod(direction + 8, 16)
		var row := posmod(direction * 16, 256)
		for index in carriages.size():
			var name := str(carriages[index])
			# A locomotive and a wagon are their own prototype types.
			var proto := Prototypes.get_p(name, name)
			if proto.is_empty():
				continue
			var position: Vector2 = simulation.trains.carriage_position(train, index)
			var cell := Vector2i(int(floor(position.x)), int(floor(position.y)))
			if cell.x < min_cell.x - 4 or cell.x > max_cell.x + 4 \
					or cell.y < min_cell.y - 4 or cell.y > max_cell.y + 4:
				continue
			var pictures: Variant = proto.get("pictures", {})
			if not (pictures is Dictionary):
				continue
			var rotated: Variant = pictures.get("rotated", pictures)
			var centre := position * TILE
			var tag := "train/%s#%d" % [name, index]
			for layer: SpriteSource.Layer in SpriteCache.layers_row(
					rotated, row, 0, 0, tag):
				var modulate := layer.modulate
				if layer.shadow:
					modulate.a *= SHADOW_ALPHA
				var item := {
					"texture": layer.texture,
					"path": layer.reference,
					"src": layer.src_rect,
					"dest": Rect2(centre + layer.offset - layer.size * 0.5,
						layer.size),
					"modulate": modulate,
					# Trains sort above the track they stand on.
					"sort_y": centre.y + 2.0,
					"seq": _sequence,
				}
				_sequence += 1
				if layer.shadow:
					shadows.append(item)
				else:
					bodies.append(item)


## Logistic robots.
##
## A robot picks its sheet from what it is doing: ``idle`` or ``in_motion``,
## with a ``_with_cargo`` variant when its arms are full, and a matching
## shadow sheet underneath.
func _emit_robots(shadows: Array, bodies: Array, min_cell: Vector2i,
		max_cell: Vector2i) -> void:
	if simulation == null:
		return

	var all: Array = simulation.logistics.robots.duplicate()
	all.append_array(simulation.logistics.builders)
	for robot: Dictionary in all:
		var position: Vector2 = Vector2(robot["position"]) * TILE
		var cell := Vector2i(int(floor(position.x / TILE)),
			int(floor(position.y / TILE)))
		if cell.x < min_cell.x - 2 or cell.x > max_cell.x + 2 \
				or cell.y < min_cell.y - 2 or cell.y > max_cell.y + 2:
			continue
		var state := str(robot.get("state", "idle"))
		var moving := state != "idle"
		var carrying := not (robot.get("carrying", {}) as Dictionary).is_empty()
		# The two robots live under their own prototype types, named after
		# themselves.
		var kind := str(robot.get("name", "logistic-robot"))
		var proto := Prototypes.get_p(kind, kind)
		if proto.is_empty():
			continue
		var key := "in_motion" if moving else "idle"
		if carrying:
			key += "_with_cargo"
		var direction := posmod(int(robot.get("direction", 8)), 16)
		var frame := int(robot.get("animation", 0.0)) % 16
		for pass_index in 2:
			var node: Variant = proto.get("shadow_%s" % key if pass_index == 0 else key)
			if not (node is Dictionary):
				continue
			var tag := "%s/%s#%d" % [kind, key, pass_index]
			for layer: SpriteSource.Layer in SpriteCache.layers(
					node, direction, frame, 0, tag):
				var modulate := layer.modulate
				if layer.shadow:
					modulate.a *= SHADOW_ALPHA
				var item := {
					"texture": layer.texture,
					"path": layer.reference,
					"src": layer.src_rect,
					"dest": Rect2(position + layer.offset - layer.size * 0.5,
						layer.size),
					"modulate": modulate,
					"sort_y": position.y + (0.0 if pass_index == 0 else 0.01),
					"seq": _sequence,
				}
				_sequence += 1
				if layer.shadow or pass_index == 0:
					shadows.append(item)
				else:
					bodies.append(item)


## The inserter's arm: a line from the pivot to the hand, with the real hand
## sprite riding at the end.
##
## The simulation already stores `swing` (0 at the pickup side, 1 at the drop
## side) and the item in `hand`; the renderer used to draw only the platform,
## so the machine looked like a static plate.  The arm sweeps between the two
## positions on every cycle and the hand changes to the closed sprite while it
## carries something.
func _emit_inserter_arm(badges: Array, entity: Entity, centre: Vector2) -> void:
	var proto := entity.prototype()
	if proto.is_empty():
		return
	var pickup_local := FactorioAssets.parse_vector(
		proto.get("pickup_position", [0.0, -1.0]))
	var insert_local := FactorioAssets.parse_vector(
		proto.get("insert_position", [0.0, 1.0]))
	var pickup := centre + Simulation.rotate_local(pickup_local,
		entity.direction) * TILE
	var drop := centre + Simulation.rotate_local(insert_local,
		entity.direction) * TILE
	var swing := clampf(float(entity.state.get("swing", 0.0)), 0.0, 1.0)
	# Rotate around the pivot rather than sliding through it: interpolating the
	# positions directly made the arm collapse to a point at mid-swing.
	var pickup_vec := pickup - centre
	var drop_vec := drop - centre
	var arm_angle := lerp_angle(pickup_vec.angle(), drop_vec.angle(), swing)
	var arm_length := lerpf(pickup_vec.length(), drop_vec.length(), swing)
	var hand_position := centre + Vector2.from_angle(arm_angle) * arm_length
	var hand: Dictionary = entity.state.get("hand", {})
	var carrying := not hand.is_empty()
	var ghost := entity.is_ghost()
	var arm_colour := Color(0.45, 0.60, 1.0, 0.45) if ghost \
		else Color(0.95, 0.78, 0.30, 0.95)

	# The arm itself.  A line is enough to read the motion at a glance.  It
	# goes with the hand into the top badge layer, not into the depth-sorted
	# world bodies, so a belt in front can never cover it.
	badges.append({
		"texture": null,
		"path": "",
		"src": Rect2(),
		"dest": Rect2(centre, Vector2.ONE),
		"modulate": arm_colour,
		"sort_y": centre.y + TILE * 0.30,
		"seq": _sequence,
		"line": [centre.x, centre.y, hand_position.x, hand_position.y,
			arm_colour.r, arm_colour.g, arm_colour.b],
		"line_alpha": arm_colour.a,
		"width": 2.5,
	})
	_sequence += 1

	var hand_node: Variant = proto.get(
		"hand_closed_picture" if carrying else "hand_open_picture", null)
	if hand_node == null:
		hand_node = proto.get("hand_base_picture", null)
	if hand_node != null:
		var tag := "inserter/hand/%s/%s" % [entity.name,
			"closed" if carrying else "open"]
		var angle := arm_angle + PI * 0.5
		var arm_pixels := maxf(10.0, hand_position.distance_to(centre))
		for layer: SpriteSource.Layer in SpriteCache.layers(hand_node, 0, 0, 0, tag):
			# The hand sheet is drawn from the pivot outwards: its lower edge
			# sits on the inserter base, its claw on the hand position.  Drawing
			# it centred on the hand made a fat bar stick out past the target.
			var width := layer.size.x
			var dest := Rect2(centre.x - width * 0.5, centre.y - arm_pixels,
				width, arm_pixels)
			badges.append({
				"texture": layer.texture,
				"path": layer.reference,
				"src": layer.src_rect,
				"dest": dest,
				"pivot": centre,
				"modulate": layer.modulate * (Color(0.45, 0.6, 1.0, 0.45)
					if ghost else Color(1, 1, 1, 1)),
				"rotation": angle,
				"sort_y": centre.y + TILE * 0.40,
				"seq": _sequence,
			})
			_sequence += 1

	if carrying:
		var icon := _item_icon(str(hand.get("name", "")))
		if icon != null:
			var size := Vector2(13, 13)
			badges.append({
				"texture": icon,
				"path": "",
				"src": Rect2(Vector2.ZERO, Vector2(icon.get_width(), icon.get_height())),
				"dest": Rect2(hand_position - size * 0.5, size),
				"modulate": Color.WHITE,
				"sort_y": centre.y + TILE * 0.55,
				"seq": _sequence,
			})
			_sequence += 1


## The engineer, drawn from the real 8-direction animation sheets.
func _emit_character(shadows: Array, bodies: Array) -> void:
	var centre := character.world_position()
	for layer: SpriteSource.Layer in character.render_layers():
		var dest := Rect2(centre + layer.offset - layer.size * 0.5, layer.size)
		var modulate := layer.modulate
		if layer.shadow:
			modulate.a *= SHADOW_ALPHA
		var item := {
			"texture": layer.texture,
			"path": layer.reference,
			"src": layer.src_rect,
			"dest": dest,
			"modulate": modulate,
			"sort_y": centre.y,
			"seq": _sequence,
		}
		_sequence += 1
		if layer.shadow:
			shadows.append(item)
		else:
			bodies.append(item)


## Items riding on belts, drawn as their inventory icons.
func _emit_belt_items(bodies: Array, min_cell: Vector2i, max_cell: Vector2i) -> void:
	if _render_scale < 0.25:
		return
	for belt: Entity in world.entities.values():
		if not BeltSim.is_belt(belt) or not _chunk_loaded(belt.origin):
			continue
		if belt.origin.x < min_cell.x - 1 or belt.origin.x > max_cell.x + 1:
			continue
		if belt.origin.y < min_cell.y - 1 or belt.origin.y > max_cell.y + 1:
			continue
		var items := BeltSim.items_of(belt)
		if items.is_empty():
			continue
		# The belt body sorts at its centre; items used to sort at their own
		# lane position, so an item on the near lane was painted *under* the
		# belt sprite and only flickered between its gaps.  Sorting just above
		# this tile's belt keeps the item visible, while still sorting behind
		# the belt of the next tile on a vertical run.
		var belt_center_y := belt.center().y * TILE
		for item: Dictionary in items:
			var icon := _item_icon(str(item["name"]))
			if icon == null:
				continue
			var position := BeltSim.item_world_position(belt, item, world) * TILE
			var size := Vector2(ITEM_ICON_PIXELS, ITEM_ICON_PIXELS)
			bodies.append({
				"texture": icon,
				"path": "",
				"src": Rect2(Vector2.ZERO, Vector2(icon.get_width(), icon.get_height())),
				"dest": Rect2(position - size * 0.5, size),
				"modulate": Color.WHITE,
				"sort_y": maxf(position.y, belt_center_y) + 6.0,
				"seq": _sequence,
			})
			_sequence += 1


## The animation frame a belt-shaped entity is showing.
## Frame for the non-belt animated graphics (drill heads, furnace fire,
## assembling machines).  Factorio's mining drill animation_speed is 0.4
## frames per tick; one shared clock is enough for every animated prototype
## and keeps the sprite cache bounded to 60 frames.
const ENTITY_ANIMATION_SPEED := 0.4


func _entity_animation_frame() -> int:
	if simulation == null:
		return 0
	return posmod(int(floor(float(simulation.tick) * ENTITY_ANIMATION_SPEED)), 60)


## Leaf-density stage for a tree: 0 full, 1 thinning, 2 nearly bare.  It is
## driven by local pollution and damage, not by time, so the sprite changes
## once when the environment does instead of cycling every few frames.
## A machine is visibly working while it has a recipe in progress.  Factorio
## puts the corresponding fire/heat/propeller artwork in
## ``working_visualisations``; EntityVisuals collects those generically.
func _machine_is_working(entity: Entity) -> bool:
	if bool(entity.state.get("working", false)):
		return true
	if simulation != null \
			and int(entity.state.get("working_tick", -1)) == simulation.tick:
		return true
	match str(entity.prototype().get("type", entity.proto_type)):
		"generator":
			return float(entity.state.get("available_power", 0.0)) > 0.0
		"boiler":
			# A boiler whose fire is lit but which has no water is idle; the
			# simulation only stamps working_tick when it actually makes steam.
			return false
		_:
			return false


func _tree_stage(entity: Entity) -> int:
	var stage := 0
	if simulation.pollution != null:
		var pollution := simulation.pollution.pollution_at(entity.origin)
		if pollution >= 300.0:
			stage = 2
		elif pollution >= 50.0:
			stage = 1
	var health: Variant = entity.state.get("health", null)
	var max_health: Variant = entity.prototype().get("max_health", null)
	if health != null and max_health != null and float(max_health) > 0.0:
		var fraction := clampf(float(health) / float(max_health), 0.0, 1.0)
		if fraction < 0.45:
			stage = maxi(stage, 2)
		elif fraction < 0.75:
			stage = maxi(stage, 1)
	return stage


func _belt_animation_frame(entity: Entity, graphics: Variant) -> int:
	var frames := 16
	if graphics is Dictionary:
		frames = maxi(1, int((graphics as Dictionary).get("frame_count", 16)))
	var speed := float(entity.prototype().get("speed", 0.03125))
	var tick := simulation.tick if simulation != null else int(_anim_time * 60.0)
	# The sheet's animation frames already advance in the direction its painted
	# arrows point.  Reversing the phase made the surface run backwards under
	# the arrows.
	var phase := int(float(tick) * maxf(speed, 0.001) * float(frames))
	return posmod(phase, frames)


## Icons are composed once per item kind and cached.
func _item_icon(item_name: String) -> Texture2D:
	if _item_icons.has(item_name):
		return _item_icons[item_name]
	var icon := FactorioAssets.prototype_icon(Prototypes.item_proto(item_name))
	_item_icons[item_name] = icon
	return icon


## Painter's order: nearer-to-the-camera entities last, and within one entity
## the sheet's own layer order.
static func _sort_by_depth(a: Dictionary, b: Dictionary) -> bool:
	var ya := float(a["sort_y"])
	var yb := float(b["sort_y"])
	if not is_equal_approx(ya, yb):
		return ya < yb
	return int(a.get("seq", 0)) < int(b.get("seq", 0))


func _variation_count(graphics: Variant) -> int:
	if graphics is Dictionary:
		if graphics.has("variation_count"):
			return maxi(1, int(graphics["variation_count"]))
		var sheets: Variant = graphics.get("sheets")
		if sheets is Array and not sheets.is_empty():
			var first: Variant = sheets[0]
			if first is Dictionary and first.has("variation_count"):
				return maxi(1, int(first["variation_count"]))
	return 1


# --------------------------------------------------------------------------
# debug overlay
# --------------------------------------------------------------------------

func _emit_grid(out: Array, _min_cell: Vector2i, _max_cell: Vector2i) -> void:
	pass
