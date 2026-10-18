class_name Minimap
extends Control
## Factorio's minimap: the world drawn one pixel per tile, with the current
## view marked on it.
##
## The colours come from the prototypes themselves — ``map_color`` on the tile,
## the resource and the entity — so the picture is the same one the original
## draws, not a hand-picked palette.  Terrain is only generated where the
## player has been, and the minimap simply asks the world for the tiles it
## needs, which generates them.
##
## The ground is drawn from ``MapChunks``: a cached 32x32 texture per chunk,
## rebuilt only when that chunk's ore or tiles change.  The entities, enemies,
## camera rectangle and the engineer are drawn live on top, so the picture
## stays current without rebuilding thousands of cells.

const TILE := 32.0
## How many tiles across the minimap shows.
const VIEW_TILES := Vector2i(224, 152)

signal tile_clicked(cell: Vector2i)

var world: GameWorld
var character: Character
var camera: GameCamera

var _chunks: MapChunks
var _style: StyleBox
var _centre := Vector2i.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(VIEW_TILES.x, VIEW_TILES.y)
	size = Vector2(VIEW_TILES)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	clip_contents = true

	_style = FactorioStyle.stylebox("inside_shallow_frame", "default")
	if _style == null:
		_style = FactorioStyle.stylebox("frame", "default")

	if world != null:
		_chunks = MapChunks.new(world)
	queue_redraw()


## The picture, the frame around it, the camera rectangle and the engineer.
func _draw() -> void:
	var rect := Rect2(Vector2(1, 1), size - Vector2(2, 2))
	if _style != null:
		draw_style_box(_style, Rect2(Vector2.ZERO, size))
	if _chunks != null:
		_draw_ground(rect)
		_draw_entities(rect)
		_draw_units(rect)
	_draw_camera(rect)
	_draw_player(rect)


## The ground: one cached 32-pixel chunk texture per chunk, clipped to the
## panel where the chunk runs over an edge.
func _draw_ground(rect: Rect2) -> void:
	var origin := _centre - VIEW_TILES / 2
	var first := Vector2i(
		int(floor(float(origin.x) / MapChunks.CHUNK)),
		int(floor(float(origin.y) / MapChunks.CHUNK)))
	var last := Vector2i(
		int(floor(float(origin.x + VIEW_TILES.x - 1) / MapChunks.CHUNK)),
		int(floor(float(origin.y + VIEW_TILES.y - 1) / MapChunks.CHUNK)))
	for cy in range(first.y, last.y + 1):
		for cx in range(first.x, last.x + 1):
			var coord := Vector2i(cx, cy)
			var texture := _chunks.texture_for(coord)
			if texture == null:
				continue
			# Top-left of the chunk in minimap pixels.
			var cell := coord * MapChunks.CHUNK
			var at := cell - origin
			var src := Rect2(0, 0, MapChunks.CHUNK, MapChunks.CHUNK)
			if at.x < 0:
				src.position.x = -at.x
				src.size.x += at.x
			if at.y < 0:
				src.position.y = -at.y
				src.size.y += at.y
			if at.x + MapChunks.CHUNK > VIEW_TILES.x:
				src.size.x = minf(src.size.x, VIEW_TILES.x - at.x - src.position.x)
			if at.y + MapChunks.CHUNK > VIEW_TILES.y:
				src.size.y = minf(src.size.y, VIEW_TILES.y - at.y - src.position.y)
			if src.size.x <= 0 or src.size.y <= 0:
				continue
			var dest := Rect2(rect.position + Vector2(maxf(0, at.x), maxf(0, at.y)),
				src.size)
			draw_texture_rect_region(texture, dest, src, Color.WHITE)


func _draw_entities(rect: Rect2) -> void:
	var origin := _centre - VIEW_TILES / 2
	for entity: Entity in world.entities.values():
		if entity.is_ghost() or entity.proto_type in [
				"item-entity", "tree", "simple-entity"]:
			continue
		var colour := _entity_colour(entity)
		if colour.a <= 0.0:
			continue
		for cell: Vector2i in entity.occupied_cells():
			var local := cell - origin
			if local.x < 0 or local.y < 0 \
					or local.x >= VIEW_TILES.x or local.y >= VIEW_TILES.y:
				continue
			draw_rect(Rect2(rect.position + Vector2(local), Vector2.ONE), colour)


func _draw_units(rect: Rect2) -> void:
	var sim := _simulation()
	if sim == null:
		return
	var origin := _centre - VIEW_TILES / 2
	for unit: Dictionary in sim.units:
		var position: Vector2 = unit["position"]
		var local := Vector2i(int(floor(position.x)), int(floor(position.y))) - origin
		if local.x < 0 or local.y < 0 \
				or local.x >= VIEW_TILES.x or local.y >= VIEW_TILES.y:
			continue
		draw_rect(Rect2(rect.position + Vector2(local), Vector2.ONE),
			Color(0.86, 0.16, 0.16))


## The rectangle the camera is looking at, clipped to the minimap.
func _draw_camera(rect: Rect2) -> void:
	if camera == null:
		return
	var view: Rect2 = camera.view_rect_world()
	var view_origin: Vector2 = view.position / TILE
	var view_size: Vector2 = view.size / TILE
	var origin := Vector2(_centre - VIEW_TILES / 2)
	var top_left := (view_origin - origin) / Vector2(VIEW_TILES)
	var extent := view_size / Vector2(VIEW_TILES)
	var marker := Rect2(rect.position + top_left * rect.size, extent * rect.size)
	marker = marker.intersection(rect)
	if marker.size.x > 0.0 and marker.size.y > 0.0:
		draw_rect(marker, Color(1, 1, 1, 0.9), false, 1.0)


## The engineer, as a blue dot with a dark rim.
func _draw_player(rect: Rect2) -> void:
	if character == null:
		return
	var origin := _centre - VIEW_TILES / 2
	var local := (character.position - Vector2(origin)) / Vector2(VIEW_TILES)
	var dot := rect.position + local * rect.size
	if not rect.grow(4.0).has_point(dot):
		return
	draw_circle(dot, 3.2, Color(0.06, 0.08, 0.1, 0.95))
	draw_circle(dot, 2.4, Color(0.35, 0.72, 1.0, 1.0))


func _process(_delta: float) -> void:
	if not visible:
		return
	if character != null:
		_centre = Vector2i(floor(character.position.x), floor(character.position.y))
	# A handful of chunk blits and entity pixels: cheap enough to follow the
	# player every frame, and it removes the periodic rebuild stalls.
	queue_redraw()


## Where the minimap is centred.
func follow(centre: Vector2i) -> void:
	_centre = centre
	queue_redraw()


## Kept as the public "redraw now" entry point.
func rebuild() -> void:
	queue_redraw()


## Composite the current view into one image, for ``--minimap-png``.
func render_image() -> Image:
	var out := Image.create(VIEW_TILES.x, VIEW_TILES.y, false, Image.FORMAT_RGBA8)
	if _chunks == null:
		return out
	var origin := _centre - VIEW_TILES / 2
	var first := Vector2i(
		int(floor(float(origin.x) / MapChunks.CHUNK)),
		int(floor(float(origin.y) / MapChunks.CHUNK)))
	var last := Vector2i(
		int(floor(float(origin.x + VIEW_TILES.x - 1) / MapChunks.CHUNK)),
		int(floor(float(origin.y + VIEW_TILES.y - 1) / MapChunks.CHUNK)))
	for cy in range(first.y, last.y + 1):
		for cx in range(first.x, last.x + 1):
			var coord := Vector2i(cx, cy)
			var chunk_image := _chunks.image_for(coord)
			if chunk_image == null:
				continue
			var at := coord * MapChunks.CHUNK - origin
			var from := Vector2i(maxi(0, -at.x), maxi(0, -at.y))
			var to := Vector2i(
				mini(MapChunks.CHUNK, VIEW_TILES.x - at.x),
				mini(MapChunks.CHUNK, VIEW_TILES.y - at.y))
			if to.x <= from.x or to.y <= from.y:
				continue
			out.blit_rect(chunk_image,
				Rect2i(from, to - from), at + from)
	return out


## The simulation that owns the enemies, for the red dots.
var _simulation_ref: Simulation


func _simulation() -> Simulation:
	return _simulation_ref


func set_simulation(sim: Simulation) -> void:
	_simulation_ref = sim


## Share the chunk picture cache with the full map.
func set_map_chunks(chunks: MapChunks) -> void:
	if chunks != null:
		_chunks = chunks
		queue_redraw()


## Buildings on the minimap.  The prototypes mostly leave ``map_color`` unset,
## so quiet machinery is grey and anything with a colour of its own keeps it.
func _entity_colour(entity: Entity) -> Color:
	var raw: Variant = entity.prototype().get("map_color")
	if raw != null:
		return MapChunks._to_colour(raw, false)
	if entity.proto_type in ["unit", "unit-spawner", "turret"]:
		return Color(0.8, 0.15, 0.15)
	if entity.proto_type in ["tree", "simple-entity"]:
		return Color(0.1, 0.3, 0.1)
	if entity.proto_type == "resource":
		return Color(0, 0, 0, 0)
	if entity.proto_type in ["transport-belt", "underground-belt", "splitter"]:
		return Color(0.55, 0.5, 0.45)
	if entity.proto_type in ["pipe", "pipe-to-ground", "pump", "storage-tank"]:
		return Color(0.5, 0.55, 0.6)
	if entity.proto_type in ["electric-pole", "big-electric-pole", "substation"]:
		return Color(0.45, 0.35, 0.25)
	return Color(0.62, 0.6, 0.58)


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return
	var fraction := Vector2(button.position.x / maxf(1.0, size.x),
		button.position.y / maxf(1.0, size.y))
	if fraction.x < 0.0 or fraction.y < 0.0 or fraction.x > 1.0 or fraction.y > 1.0:
		return
	var origin := _centre - VIEW_TILES / 2
	var cell := origin + Vector2i(int(fraction.x * VIEW_TILES.x),
		int(fraction.y * VIEW_TILES.y))
	tile_clicked.emit(cell)
	accept_event()
