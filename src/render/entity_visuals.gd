class_name EntityVisuals
extends RefCounted
## Maps an entity prototype onto the graphics nodes that should be drawn.
##
## Factorio names the artwork property differently for almost every entity
## type (``animation``, ``pictures``, ``graphics_set``, ``belt_animation_set``,
## ``variations``, ...) and nests it a level or two deep.  This is the single
## place that knows those conventions.
##
## ``visual()`` returns:
##   ``nodes``     -- one or more graphics nodes, painted in order
##   ``direction`` -- the row index to hand to the sprite resolver, because
##                    some sheets (belts, pipes) index rows by *shape* rather
##                    than by rotation

## Belt shape rows inside ``transport-belt.png``.
##
## The sheet holds twenty shapes: rows 0-3 are the four straight runs, rows
## 4-11 the eight curves and rows 12-19 belt ends and loaders.  The straights
## were read straight off the arrows; the curves were worked out from which
## tile edges each sprite's belt surface reaches, and are indexed here by
## (travel direction, side the items arrive from).
## The sheet's straights are: row 0 east, row 1 west, row 2 north, row 3 south.
## Sheet rows 0-3 are east/west/north/south, as painted by their arrows.
## The animation frames themselves scroll the other way and are reversed by
## the renderer's belt frame clock.
const BELT_STRAIGHT := {0: 2, 4: 0, 8: 3, 12: 1}

## ``direction -> { right: row, left: row }``.  "Right" and "left" are the side
## of the belt the feeding line comes in on, seen from the belt's own heading.
const BELT_CURVES := {
	# Row 4 is the left turn E->N; row 5 is its mirror N->E.  The other
	# pairs keep their original handedness.
	0: {"right": 4, "left": 7},    # heading north: E->N, W->N
	4: {"right": 8, "left": 5},    # heading east: S->E, N->E
	8: {"right": 10, "left": 9},   # heading south: W->S, E->S
	12: {"right": 6, "left": 11},  # heading west: N->W, S->W
}


## Everything needed to draw one entity: ``{ nodes, direction }``.
##
## ``world`` is only needed by entities whose artwork depends on their
## neighbours — pipes pick one of eighteen connection shapes.
##
## Working visualisations are collected generically: Factorio puts furnace
## fire, electric-furnace heaters, drill smoke and similar effects in
## ``graphics_set.working_visualisations`` on many different prototypes.  The
## wrapper adds ``always_draw`` entries to the normal node list and keeps the
## rest in ``working_nodes`` for the renderer to show only while the machine
## actually has a recipe in progress.
static func visual(entity: Entity, frame := 0, world: GameWorld = null) -> Dictionary:
	var data := _base_visual(entity, frame, world)
	if data.is_empty():
		return data
	var proto := entity.prototype()
	var working: Array = []
	var always: Array = []
	for vis: Variant in _working_visualisations(proto):
		if not (vis is Dictionary):
			continue
		var anim := _working_animation(vis, entity.direction)
		if anim == null:
			continue
		if bool((vis as Dictionary).get("always_draw", false)):
			always.append(anim)
		else:
			working.append(anim)
	if not always.is_empty():
		var nodes: Array = data.get("nodes", [])
		nodes.append_array(always)
		data["nodes"] = nodes
	if not working.is_empty():
		data["working_nodes"] = working
	return data


## Every ``working_visualisations`` list a prototype may carry.
static func _working_visualisations(proto: Dictionary) -> Array:
	var out: Array = []
	var gs: Variant = proto.get("graphics_set", {})
	if gs is Dictionary:
		var list: Variant = (gs as Dictionary).get("working_visualisations", [])
		if list is Array:
			out.append_array(list)
	var top: Variant = proto.get("working_visualisations", [])
	if top is Array:
		out.append_array(top)
	return out


static func _base_visual(entity: Entity, frame := 0, world: GameWorld = null) -> Dictionary:
	var proto := entity.prototype()
	if proto.is_empty():
		return {}
	var type_name: String = str(proto.get("type", entity.proto_type))
	var direction := entity.direction

	match type_name:
		"resource":
			return _result([proto.get("stages", {})], 0)

		"transport-belt":
			var set: Variant = proto.get("belt_animation_set", {})
			if set is Dictionary and set.has("animation_set"):
				var row := int(BELT_STRAIGHT.get(posmod(direction, 16), 0))
				if world != null:
					row = belt_shape_row(world, entity)
				# The belt sheet's twenty rows are connection *shapes*, not
				# rotations: row 3 is a north-going straight, rows 4-11 the
				# curves.  Passing the row through the direction mapper drew a
				# different shape for every belt (and the wrong one at that).
				return {
					"nodes": [set["animation_set"]],
					"direction": row,
					"is_row": true,
				}
			return {}

		"underground-belt":
			# An entrance disappears into the ground and an exit rises out of
			# it, so each half takes a belt-end row rather than a rotation.
			var uset: Variant = proto.get("belt_animation_set", {})
			if uset is Dictionary and uset.has("animation_set"):
				return {
					"nodes": [uset["animation_set"]],
					"direction": underground_shape_row(entity),
					"is_row": true,
				}
			return {}

		"splitter":
			# Two belt-wide columns drawn side by side; the shared animation
			# set is a single-tile sheet, so each half is its own node.
			var sset: Variant = proto.get("belt_animation_set", {})
			if sset is Dictionary and sset.has("animation_set"):
				var srow := int(BELT_STRAIGHT.get(posmod(direction, 16), 0))
				var side := lane_offset_vector(entity.direction)
				return {
					"nodes": [sset["animation_set"], sset["animation_set"]],
					"offsets": [Vector2.ZERO, side],
					"direction": srow,
					"is_row": true,
				}
			return {}

		"accumulator":
			# An accumulator's body is inside its chargable graphics.
			var chargable: Variant = proto.get("chargable_graphics", {})
			if chargable is Dictionary and (chargable as Dictionary).has("picture"):
				return _result([(chargable as Dictionary)["picture"]], 0)
			return {}

		"rocket-silo":
			# The silo is a stack of animations; the base is the front arm.
			var arms: Array = []
			for key: String in ["arm_01_back_animation", "arm_02_right_animation",
					"arm_03_front_animation"]:
				if proto.has(key):
					arms.append(proto[key])
			if proto.has("satellite_animation"):
				arms.append(proto["satellite_animation"])
			return _result(arms, 0)

		"land-mine":
			var picture: Variant = proto.get("picture_set", proto.get("picture_safe"))
			return _result([picture], 0) if picture != null else {}

		"constant-combinator", "arithmetic-combinator", "decider-combinator":
			# Four orientations, plus the symbol on the face that says which
			# operation or comparison the device is set to.
			var by_side: Variant = proto.get("sprites", {})
			var nodes: Array = []
			if by_side is Dictionary and not (by_side as Dictionary).is_empty():
				nodes.append((by_side as Dictionary).get(_side_name(direction),
					(by_side as Dictionary).values()[0]))
			var symbol := _combinator_symbol(proto, entity)
			if symbol != null:
				nodes.append(symbol)
			return _result(nodes, 0)

		"programmable-speaker":
			return _result([proto.get("sprite", {})], 0)

		"curved-rail-a", "curved-rail-b", "half-diagonal-rail":
			# Curves are keyed by the eight compass sides, not by an axis.
			var by_side: Variant = proto.get("pictures", {})
			if by_side is Dictionary:
				var key := _side_name(direction)
				var curve_set: Variant = (by_side as Dictionary).get(key, null)
				if curve_set is Dictionary:
					var curve_nodes: Array = []
					for layer_name: String in curve_set:
						curve_nodes.append(curve_set[layer_name])
					return _result(curve_nodes, 0)
			return {}

		"train-stop":
			# Four orientations, each an animation of a few layers.
			var by_side: Variant = proto.get("animations", {})
			if by_side is Dictionary and not (by_side as Dictionary).is_empty():
				var side := _side_name(direction)
				var animation: Variant = by_side.get(side,
					(by_side as Dictionary).values()[0])
				return _result([animation], 0)
			return {}

		"straight-rail":
			var pictures: Variant = proto.get("pictures", {})
			if pictures is Dictionary:
				# ``north`` is the vertical run and ``east`` the horizontal
				# one; each is a set of layers to paint in order.
				var key := "north" if posmod(direction, 8) == 0 else "east"
				var set: Variant = pictures.get(key, pictures.get("north"))
				if set is Dictionary:
					var nodes: Array = []
					for layer_name: String in set:
						nodes.append(set[layer_name])
					return _result(nodes, 0)
			return {}

		"assembling-machine", "rocket-silo":
			var gs: Variant = proto.get("graphics_set", {})
			if gs is Dictionary and gs.has("animation"):
				# Oil refineries and chemical plants key `animation` by the
				# four compass sides; assembling machines keep one layered
				# animation.  Passing the direction table straight to the
				# sprite resolver produced no layers at all.
				return _result([_direction_animation(gs["animation"], direction)], 0)
			for key in ["animation", "idle_animation"]:
				if proto.has(key):
					return _result([_direction_animation(proto[key], direction)], 0)

		"furnace":
			var fgs: Variant = proto.get("graphics_set", {})
			if fgs is Dictionary and fgs.has("animation"):
				return _result([_direction_animation(fgs["animation"], direction)], 0)

		"lab":
			for key in ["on_animation", "animation", "off_animation"]:
				if proto.has(key):
					return _result([proto[key]], 0)

		"ammo-turret", "electric-turret", "fluid-turret", "artillery-turret":
			for key in ["folded_animation", "preparing_animation"]:
				if proto.has(key):
					return _result([proto[key]], 0)
			if proto.has("base_visualisation"):
				return _result([proto["base_visualisation"]], 0)

		"mining-drill":
			var dgs: Variant = proto.get("graphics_set", {})
			if dgs is Dictionary and dgs.has("animation"):
				var picked: Variant = _direction_animation(dgs["animation"], direction)
				return _result([picked], 0)
			if dgs is Dictionary and dgs.has("base_picture"):
				return _result([dgs["base_picture"]], 0)

		"boiler":
			var bpic: Variant = _direction_node(proto.get("pictures", {}), direction)
			if bpic is Dictionary:
				var nodes: Array = []
				for key in ["structure", "fire", "fire_glow"]:
					if bpic.has(key):
						nodes.append(bpic[key])
				if not nodes.is_empty():
					return _result(nodes, 0)

		"generator":
			var gpic: Variant = _direction_node(proto.get("pictures", {}), direction)
			if gpic is Dictionary and not (gpic as Dictionary).is_empty():
				var gnodes: Array = []
				for key in ["frozen", "picture", "vertical_frames"]:
					if gpic.has(key):
						gnodes.append(gpic[key])
				if gnodes.is_empty():
					gnodes.append(gpic)
				return _result(gnodes, 0)
			# Steam engines animate horizontally or vertically depending on
			# whether the neighbouring boilers sit left/right or above/below.
			var vertical: bool = direction == 0 or direction == 8
			var key2 := "vertical_animation" if vertical else "horizontal_animation"
			if proto.has(key2):
				return _result([proto[key2]], 0)

		"beacon":
			var bset: Variant = proto.get("graphics_set", {})
			if bset is Dictionary:
				var list: Variant = bset.get("animation_list", [])
				if list is Array and not list.is_empty():
					var first: Variant = list[0]
					if first is Dictionary and first.has("animation"):
						first = first["animation"]
					return _result([first], 0)

		"roboport":
			var rnodes: Array = []
			for key in ["base", "base_patch"]:
				if proto.has(key):
					rnodes.append(proto[key])
			if not rnodes.is_empty():
				return _result(rnodes, 0)

		"pipe":
			var ppic: Variant = proto.get("pictures", {})
			if ppic is Dictionary and ppic.has("straight_vertical_single"):
				var key := "straight_vertical_single"
				if world != null:
					key = pipe_picture_key(world, entity)
				var picked: Variant = ppic.get(key, ppic["straight_vertical_single"])
				return _result([picked], 0)
		"pipe-to-ground", "pump":
			var gpic: Variant = proto.get("pictures", {})
			if gpic is Dictionary and gpic.has("straight_vertical_single"):
				return _result([gpic["straight_vertical_single"]], 0)

		"unit-spawner":
			# Biter/spitter nests keep four idle animations under
			# graphics_set.animations.  The generic path treated the whole
			# graphics_set dictionary as one sprite, so nests were invisible.
			var sgs: Variant = proto.get("graphics_set", {})
			if sgs is Dictionary:
				var anims: Variant = (sgs as Dictionary).get("animations", [])
				if anims is Array and not (anims as Array).is_empty():
					var index := SpriteSource.variation_for(entity.origin,
						(anims as Array).size())
					return _result([(anims as Array)[index]], 0)
			return _generic(proto, direction)

		"offshore-pump":
			# The pump is four directional animations under graphics_set.animation,
			# not the generic "picture" path; without this it drew nothing.
			var ogs: Variant = proto.get("graphics_set", {})
			if ogs is Dictionary and ogs.has("animation"):
				var opicked: Variant = _direction_animation(
					ogs["animation"], direction)
				if opicked != null:
					return _result([opicked], 0)
			return _generic(proto, direction)

		"tree":
			var variation := _tree_variation(proto, entity)
			if not variation.is_empty():
				var parts: Array = []
				# `normal` in Factorio's tree sheets is a normal map, not the
				# tree itself.  Drawing it made the canopy flicker between a
				# bare tree and a full one when the generic animation frame
				# walked 0..2; use the real trunk/leaves/shadow layers instead.
				for key in ["trunk", "leaves", "shadow"]:
					if variation.has(key):
						parts.append(variation[key])
				if not parts.is_empty():
					return _result(parts, 0)
			# Dry/dead trees keep their variants in a plain `pictures` list.
			var pictures: Variant = proto.get("pictures", null)
			if pictures is Array and not (pictures as Array).is_empty():
				var index := SpriteSource.variation_for(entity.origin,
					(pictures as Array).size())
				return _result([(pictures as Array)[index]], 0)

		"simple-entity":
			# Rocks keep their variants in `pictures`; draw one of them by
			# position instead of stacking every rock picture on one tile.
			var pictures: Variant = proto.get("pictures", null)
			if pictures is Array and not (pictures as Array).is_empty():
				var index := SpriteSource.variation_for(entity.origin,
					(pictures as Array).size())
				return _result([(pictures as Array)[index]], 0)
			if proto.has("picture"):
				return _result([proto["picture"]], 0)

		"inserter":
			# The platform sheet holds four orientations.  The hand is drawn by
			# the renderer as a moving arm, because its position depends on the
			# swing state, not on the entity's direction alone.
			var platform: Variant = proto.get("platform_picture", null)
			if platform is Dictionary:
				var node: Dictionary = (platform as Dictionary).duplicate(true)
				var sheet: Variant = node.get("sheet")
				if sheet is Dictionary:
					# Four 105x79 frames side by side; pick the one facing the
					# entity's direction instead of rotating the north sprite.
					(sheet as Dictionary)["direction_count"] = 4
					(sheet as Dictionary)["line_length"] = 4
				return {"nodes": [node], "direction": direction}
			return _generic(proto, direction)

		"electric-pole":
			var pole: Variant = _direction_node(proto.get("pictures", {}), direction)
			if pole != null:
				return _result([pole], 0)

		"wall", "gate", "reactor", "heat-pipe", "solar-panel", "accumulator", "radar", "roboport", "beacon", "car", "spider-vehicle", "arithmetic-combinator", "decider-combinator", "constant-combinator", "programmable-speaker", "train-stop", "rail-signal", "rail-chain-signal":
			var handled := _generic(proto, direction)
			if not handled.is_empty():
				return handled

	# Generic fallbacks shared by chests, belts, trains, decoratives...
	return _generic(proto, direction)


static func _generic(proto: Dictionary, direction: int) -> Dictionary:
	for key in ["picture", "pictures", "base", "base_picture", "animation", "animations",
			"graphics_set", "horizontal_animation", "vertical_animation", "structure"]:
		if not proto.has(key):
			continue
		var node: Variant = proto[key]
		# graphics_set wraps the real sprite under animation / animations.
		if key == "graphics_set" and node is Dictionary:
			if node.has("animation"):
				node = node["animation"]
			elif node.has("animations"):
				node = node["animations"]
		# A list of animations (beacons, some machines) uses the first entry.
		if node is Array and not node.is_empty() and node[0] is Dictionary \
				and (node[0] as Dictionary).has("layers"):
			return _result([node[0]], direction)
		if node is Dictionary and _is_direction_table(node):
			var entry: Variant = _direction_animation(node, direction)
			if entry != null:
				return _result([entry], 0)
		if node is Dictionary and node.has("animation_list"):
			var list: Variant = node["animation_list"]
			if list is Array and not list.is_empty():
				return _result([list[0]], 0)
		if node is Dictionary and node.has("animations"):
			var anims: Variant = node["animations"]
			if anims is Array and not anims.is_empty():
				return _result([anims[0]], 0)
		return _result([node], 0)
	return {}


## The animation a working visualisation uses for one of the four rotations.
static func _working_animation(vis: Dictionary, direction: int) -> Variant:
	var name := "north"
	match posmod(int(round(float(direction) / 4.0)) * 4, 16):
		4:
			name = "east"
		8:
			name = "south"
		12:
			name = "west"
	var key := "%s_animation" % name
	if vis.has(key):
		return vis[key]
	if vis.has("animation"):
		return vis["animation"]
	return null


## Whether a graphics node actually holds more than one animation frame.
static func _has_animation_frames(node: Variant, depth := 0) -> bool:
	if depth > 6:
		return false
	if node is Array:
		for entry: Variant in node:
			if _has_animation_frames(entry, depth + 1):
				return true
		return false
	if not (node is Dictionary):
		return false
	var dict := node as Dictionary
	if int(dict.get("frame_count", 0)) > 1:
		return true
	for key: String in ["layers", "sheets"]:
		if dict.has(key) and _has_animation_frames(dict[key], depth + 1):
			return true
	return false


## ``pictures`` may be keyed by direction name or hold a single picture.
static func _direction_node(pictures: Variant, direction: int) -> Variant:
	if pictures is Dictionary and _is_direction_table(pictures):
		return SpriteSource.direction_entry(pictures, direction)
	return pictures


static func _tree_variation(proto: Dictionary, entity: Entity) -> Dictionary:
	var variations: Variant = proto.get("variations")
	if not (variations is Array) or variations.is_empty():
		return {}
	var index := SpriteSource.variation_for(entity.origin, variations.size())
	var entry: Variant = variations[index]
	return entry if entry is Dictionary else {}


## The little symbol a combinator wears, chosen by what it is set to do.
static func _combinator_symbol(proto: Dictionary, entity: Entity) -> Variant:
	var prefix := ""
	if entity.proto_type == "arithmetic-combinator":
		var config: Variant = entity.state.get("arithmetic", null)
		var op := str((config as Dictionary).get("op", "+")) \
			if config is Dictionary else "+"
		prefix = {"+": "plus", "-": "minus", "*": "multiply", "/": "divide",
			"%": "modulo", "^": "power", "<<": "left_shift",
			">>": "right_shift", "AND": "and", "OR": "or",
			"XOR": "xor"}.get(op, "plus")
	elif entity.proto_type == "decider-combinator":
		var config: Variant = entity.state.get("decider", null)
		var cmp := str((config as Dictionary).get("cmp", ">")) \
			if config is Dictionary else ">"
		prefix = {">": "greater", "<": "less", "=": "equal", "!=": "not_equal",
			"<=": "less_or_equal", ">=": "greater_or_equal"}.get(cmp, "greater")
	else:
		return null
	var table: Variant = proto.get("%s_symbol_sprites" % prefix, {})
	if not (table is Dictionary):
		return null
	return (table as Dictionary).get("north", null)


## Which of the four side names a 16-way direction faces.
static func _side_name(direction: int) -> String:
	match posmod(direction, 16):
		0: return "north"
		4: return "east"
		8: return "south"
		12: return "west"
	return ["north", "east", "south", "west"][int(round(
		posmod(direction, 16) / 4.0)) % 4]


static func _result(nodes: Array, direction: int) -> Dictionary:
	var clean: Array = []
	for node: Variant in nodes:
		if node != null:
			clean.append(node)
	if clean.is_empty():
		return {}
	return {"nodes": clean, "direction": direction}


## Resolve a nested animation node for a direction.
##
## Several Factorio graphics layouts wrap the actual sheet twice:
## ``graphics_set.animation.north.layers`` or
## ``animation.north.animation.layers``.  Centralising the unwrap here keeps
## every caller (assembling machines, furnaces, drills, pumps, generic
## fallback) from accidentally handing a compass table to the sprite resolver,
## which silently produced no layers and therefore an invisible machine.
static func _direction_animation(node: Variant, direction: int) -> Variant:
	if node is Dictionary and _is_direction_table(node as Dictionary):
		node = SpriteSource.direction_entry(node, direction)
	if node is Dictionary and (node as Dictionary).has("animation") \
			and not (node as Dictionary).has("layers"):
		node = (node as Dictionary)["animation"]
	if node is Array and not (node as Array).is_empty():
		node = (node as Array)[0]
	return node


static func _is_direction_table(node: Dictionary) -> bool:
	return node.has("north") or node.has("east")


## Sideways unit vector for an entity's direction, used to place the two
## halves of a splitter.
static func lane_offset_vector(direction: int) -> Vector2:
	var forward := Vector2(BeltSim.dir_vector(direction))
	return Vector2(-forward.y, forward.x)


## Which belt-end shape an underground belt shows.
##
## Rows 12-19 of the belt sheet are the ends: 12/13 face north, 14/15 east,
## 16/17 south and 18/19 west (or the reverse — the pair is the belt surface
## and its shadow), so an entrance pointing one way looks like a belt running
## into the ground.
static func underground_shape_row(entity: Entity) -> int:
	var facing := posmod(entity.direction, 16)
	var is_input := str(entity.state.get("io", "input")) == "input"
	# An entrance is drawn as a belt heading into the tile (its shape faces the
	# way it travels); an exit as one coming back out.
	var row := 12 if is_input else 16
	match facing:
		0: row = 12 if is_input else 16      # north
		4: row = 14 if is_input else 18      # east
		8: row = 16 if is_input else 12      # south
		12: row = 18 if is_input else 14     # west
	return row


## Which of the twenty belt shapes a belt needs.
##
## A belt takes items straight from behind, or turns them in from either side;
## the shape follows from which neighbour actually feeds it.
static func belt_shape_row(world: GameWorld, belt: Entity) -> int:
	var direction := posmod(belt.direction, 16)
	var straight: int = BELT_STRAIGHT.get(direction, 0)
	var back := posmod(direction + 8, 16)
	if _belt_feeds(world, belt, back):
		return straight
	for offset: int in [4, 12]:
		var side := posmod(direction + offset, 16)
		if _belt_feeds(world, belt, side):
			var curves: Dictionary = BELT_CURVES.get(direction, {})
			return int(curves.get("right" if offset == 4 else "left", straight))
	return straight


## Whether the belt one tile away in ``from_direction`` feeds into ``belt``.
static func _belt_feeds(world: GameWorld, belt: Entity, from_direction: int) -> bool:
	var feeder := world.entity_at(belt.origin + BeltSim.dir_vector(from_direction))
	if not BeltSim.is_belt(feeder):
		return false
	# The feeder has to be pointing back at us.
	return posmod(feeder.direction, 16) == posmod(from_direction + 8, 16)


## Which of the eighteen pipe pictures a pipe needs.
##
## Factorio names them after the shape that gets drawn: ``t_up`` is a T whose
## stem points up (so it carries fluid north, east and west), and
## ``corner_up_right`` bends between north and east.  A pipe only draws a stub
## where its ``pipe_connections`` actually meet a neighbour's.
static func pipe_picture_key(world: GameWorld, entity: Entity) -> String:
	var north := _pipe_links_to(world, entity, Vector2i(0, -1))
	var east := _pipe_links_to(world, entity, Vector2i(1, 0))
	var south := _pipe_links_to(world, entity, Vector2i(0, 1))
	var west := _pipe_links_to(world, entity, Vector2i(-1, 0))
	var count := (1 if north else 0) + (1 if east else 0) + (1 if south else 0) + (1 if west else 0)

	match count:
		0:
			return "straight_vertical_single"
		1:
			if north:
				return "ending_up"
			if south:
				return "ending_down"
			if west:
				return "ending_left"
			return "ending_right"
		3:
			if not south:
				return "t_up"
			if not north:
				return "t_down"
			if not west:
				return "t_right"
			return "t_left"
		4:
			return "cross"
		_:
			pass
	if north and south:
		return "straight_vertical"
	if east and west:
		return "straight_horizontal"
	if north and east:
		return "corner_up_right"
	if north and west:
		return "corner_up_left"
	if south and east:
		return "corner_down_right"
	return "corner_down_left"


## Whether a pipe reaches the neighbour one tile away in ``offset``.
static func _pipe_links_to(world: GameWorld, entity: Entity, offset: Vector2i) -> bool:
	var neighbour := world.entity_at(entity.origin + offset)
	if neighbour == null:
		return false
	if not FluidSystem.has_fluid(neighbour):
		return false
	# Two plain pipes always join; anything else has to point back at us.
	var proto := neighbour.prototype()
	if str(proto.get("type", "")) == "pipe":
		return true
	return FluidSystem.connects(world, entity, neighbour)


## Convenience wrapper for callers that only need the first graphics node.
static func graphics_for(entity: Entity, frame := 0) -> Variant:
	var data := visual(entity, frame)
	var nodes: Array = data.get("nodes", [])
	return nodes[0] if not nodes.is_empty() else null


## All graphics nodes of an entity, in painting order.
static func nodes_for(entity: Entity, frame := 0) -> Array:
	return visual(entity, frame).get("nodes", [])


## Variation index so adjacent identical entities do not look cloned.
static func variation_for(entity: Entity, variation_count: int) -> int:
	if variation_count <= 1:
		return 0
	return SpriteSource.variation_for(entity.origin, variation_count)
