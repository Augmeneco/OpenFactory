class_name MapWindow
extends Control
## The full map, on M.
##
## Factorio's map is the world seen from above: the ground at a few pixels a
## tile, the ore on top of it, and a badge for every machine.  The ground comes
## from the same cached chunk pictures the minimap uses (``MapChunks``), so
## opening the map or panning it never walks hundreds of thousands of cells in
## GDScript.  Machines and pollution are stamped on top, and the engineer is a
## control overlay that follows every frame.

const MIN_SCALE := 2.0
const MAX_SCALE := 8.0
const SCALE_STEP := 1.0
## How often the picture is rebuilt while the map is open, in frames.
const REFRESH_FRAMES := 10
## Pollution is blended at this many tiles per sampled block.
const POLLUTION_STEP := 8

signal view_requested(cell: Vector2i)

var world: GameWorld
var simulation: Simulation
var character: Character

## Pixels per tile.  Named apart from Control's own `scale`.
var pixels_per_tile := 3.0
## The tile at the top-left corner of the picture.
var origin := Vector2i.ZERO

var show_ore := true
var show_entities := true
var show_pollution := false

var _frame: PanelContainer
var _picture: TextureRect
var _status: Label
var _frames := 0

## The engineer marker and the ground cache.  The marker is an overlay rather
## than a stamped pixel: it stays visible while the map is panned and does not
## force the whole picture to rebuild every time the engineer takes a step.
var _marker: ColorRect
var _chunks: MapChunks
var _last_revision := -1
var _last_tiles := Vector2i.ZERO
var _entity_colours: Dictionary = {}
var _blend_pixel: Image
## Centre requested while the window was still waiting for its first layout
## pass.  Reading `_picture.size` at that moment gives the 640x480 minimum, not
## the real map area, which used to leave the map off-centre.
var _pending_centre := Vector2i(2147483647, 2147483647)
var _pending_wait := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiKit.fill_parent(self)
	visible = false
	_build()
	set_process(true)


func _build() -> void:
	var wash := ColorRect.new()
	wash.color = Color(0, 0, 0, 0.9)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wash)
	UiKit.fill_parent(wash)

	var column := UiKit.column(4)
	add_child(column)
	UiKit.fill_parent(column)

	var head := UiKit.row(6)
	head.add_child(UiKit.label("Map", "frame_subheading_label"))
	head.add_child(_toggle("Ore", true, func(on: bool) -> void:
		show_ore = on
		rebuild()))
	head.add_child(_toggle("Machines", true, func(on: bool) -> void:
		show_entities = on
		rebuild()))
	head.add_child(_toggle("Pollution", false, func(on: bool) -> void:
		show_pollution = on
		rebuild()))
	head.add_child(_toggle("Grid", false, func(on: bool) -> void:
		pixels_per_tile = SCALE_STEP if pixels_per_tile > SCALE_STEP else MIN_SCALE
		rebuild()))
	_status = UiKit.label("", "label")
	head.add_child(_status)
	var close := UiKit.button("Close", "button")
	close.pressed.connect(close_window)
	head.add_child(close)
	column.add_child(head)

	_picture = TextureRect.new()
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_picture.stretch_mode = TextureRect.STRETCH_SCALE
	_picture.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_picture.custom_minimum_size = Vector2(640, 480)
	_picture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_picture.clip_contents = true
	_picture.mouse_filter = Control.MOUSE_FILTER_STOP
	_picture.gui_input.connect(_on_picture_input)
	column.add_child(_picture)

	_marker = ColorRect.new()
	_marker.color = Color(0.35, 0.72, 1.0, 1.0)
	_marker.custom_minimum_size = Vector2(5, 5)
	_marker.size = Vector2(5, 5)
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.visible = false
	_picture.add_child(_marker)


func _toggle(text: String, on: bool, action: Callable) -> CheckBox:
	var box := CheckBox.new()
	box.text = text
	box.button_pressed = on
	box.toggled.connect(action)
	return box


# --------------------------------------------------------------------------
# drawing
# --------------------------------------------------------------------------

## Rebuild the screen-sized picture from the cached chunk images.
func rebuild() -> void:
	if world == null or _picture == null:
		return
	if _chunks == null:
		_chunks = MapChunks.new(world)

	var screen := _map_screen()
	var tiles := Vector2i(maxi(16, int(screen.x / pixels_per_tile)),
		maxi(16, int(screen.y / pixels_per_tile)))

	# One pixel per tile first: blitting cached chunks at tile resolution is
	# C++ work, and the final resize gives the map its zoom.
	var base := Image.create(tiles.x, tiles.y, false, Image.FORMAT_RGBA8)
	_fill_satellite_noise(base, tiles)
	var first := Vector2i(
		int(floor(float(origin.x) / MapChunks.CHUNK)),
		int(floor(float(origin.y) / MapChunks.CHUNK)))
	var last := Vector2i(
		int(floor(float(origin.x + tiles.x - 1) / MapChunks.CHUNK)),
		int(floor(float(origin.y + tiles.y - 1) / MapChunks.CHUNK)))
	for cy in range(first.y, last.y + 1):
		for cx in range(first.x, last.x + 1):
			var coord := Vector2i(cx, cy)
			var chunk_image := _chunks.image_for(coord, false, show_ore)
			if chunk_image == null:
				continue
			var at := coord * MapChunks.CHUNK - origin
			var from := Vector2i(maxi(0, -at.x), maxi(0, -at.y))
			var to := Vector2i(
				mini(MapChunks.CHUNK, tiles.x - at.x),
				mini(MapChunks.CHUNK, tiles.y - at.y))
			if to.x <= from.x or to.y <= from.y:
				continue
			base.blit_rect(chunk_image, Rect2i(from, to - from), at + from)

	if show_entities:
		_stamp_entities(base, tiles)
	if show_pollution and simulation != null and simulation.pollution != null:
		_stamp_pollution(base, tiles)

	var scale := int(maxf(1.0, round(pixels_per_tile)))
	if scale != 1:
		base.resize(tiles.x * scale, tiles.y * scale, Image.INTERPOLATE_NEAREST)
	var texture := ImageTexture.create_from_image(base)
	_picture.texture = texture
	_last_tiles = tiles
	_last_revision = world.revision
	_status.text = "%d x %d tiles at %.1f px   |   %d entities   |   click a discovered area to view it" % [
		tiles.x, tiles.y, pixels_per_tile, world.entities.size()]
	_update_marker()


## Unexplored ground is rendered as a soft, deterministic satellite-noise
## field.  The coarse image is scaled up with bilinear filtering, so it looks
## like blurred static rather than a black rectangle or real terrain.
func _fill_satellite_noise(base: Image, tiles: Vector2i) -> void:
	var low := Vector2i(maxi(4, tiles.x / 7), maxi(4, tiles.y / 7))
	var field := Image.create(low.x, low.y, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(origin.x) * 73856093 ^ int(origin.y) * 19349663 ^ 0x5f3759df
	for y in low.y:
		for x in low.x:
			var v := rng.randf_range(0.055, 0.30)
			field.set_pixel(x, y, Color(v * 0.82, v * 0.9, v, 1.0))
	field.resize(tiles.x, tiles.y, Image.INTERPOLATE_BILINEAR)
	base.blit_rect(field, Rect2i(Vector2i.ZERO, tiles), Vector2i.ZERO)


## One pixel per machine footprint.
func _stamp_entities(base: Image, tiles: Vector2i) -> void:
	for entity: Entity in world.entities.values():
		if entity.is_ghost() or entity.proto_type in [
				"item-entity", "tree", "simple-entity"]:
			continue
		var entity_chunk := GameWorld.chunk_of(entity.origin)
		if not world.is_generated(entity_chunk) \
				or not world.is_chunk_revealed(entity_chunk):
			continue
		var x := entity.origin.x - origin.x
		var y := entity.origin.y - origin.y
		if x < 0 or y < 0 or x >= tiles.x or y >= tiles.y:
			continue
		var colour: Variant = _entity_colours.get(entity.proto_type)
		if colour == null:
			colour = _entity_colour(entity)
			_entity_colours[entity.proto_type] = colour
		var w := mini(entity.size.x, tiles.x - x)
		var h := mini(entity.size.y, tiles.y - y)
		base.fill_rect(Rect2i(x, y, maxi(1, w), maxi(1, h)), colour)


## A coarse brown haze over polluted ground, blended in sampled blocks.
func _stamp_pollution(base: Image, tiles: Vector2i) -> void:
	if _blend_pixel == null:
		_blend_pixel = Image.create(1, 1, false, Image.FORMAT_RGBA8)
	var step := POLLUTION_STEP
	for y in range(0, tiles.y, step):
		for x in range(0, tiles.x, step):
			var cell := origin + Vector2i(x, y)
			var coord := GameWorld.chunk_of(cell)
			if not world.is_generated(coord) or not world.is_chunk_revealed(coord):
				continue
			var amount := simulation.pollution.pollution_at(cell)
			if amount <= 0.5:
				continue
			var wash := clampf(amount / 400.0, 0.0, 0.8)
			_blend_pixel.set_pixel(0, 0,
				Color(0.47, 0.24, 0.16, wash))
			var w := mini(step, tiles.x - x)
			var h := mini(step, tiles.y - y)
			base.blend_rect(_blend_pixel, Rect2i(0, 0, 1, 1),
				Vector2i(x, y))


## What a machine looks like on the map: its prototype's `map_color`.
func _entity_colour(entity: Entity) -> Color:
	var raw: Variant = entity.prototype().get("map_color")
	if raw != null:
		return MapChunks._to_colour(raw, false)
	if entity.proto_type in ["unit", "unit-spawner", "turret"]:
		return Color(0.8, 0.15, 0.15)
	if entity.proto_type in ["tree", "simple-entity"]:
		return Color(0.1, 0.3, 0.1)
	if entity.proto_type in ["transport-belt", "underground-belt", "splitter"]:
		return Color(0.55, 0.5, 0.45)
	if entity.proto_type in ["pipe", "pipe-to-ground", "pump"]:
		return Color(0.45, 0.6, 0.65)
	return Color(0.7, 0.62, 0.45)


# --------------------------------------------------------------------------
# moving about
# --------------------------------------------------------------------------

## The map's visible area.  A TextureRect that has not been through a layout
## pass yet reports its 640x480 minimum, so the viewport is used as a floor.
func _map_screen() -> Vector2:
	var viewport := get_viewport_rect().size
	var estimate := Vector2(viewport.x, maxf(200.0, viewport.y - 40.0))
	if _picture == null:
		return estimate
	return Vector2(maxf(_picture.size.x, estimate.x),
		maxf(_picture.size.y, estimate.y))


## Centre the picture on a cell.
func centre_on(cell: Vector2i) -> void:
	var screen := _map_screen()
	origin = cell - Vector2i(int(screen.x / pixels_per_tile) / 2,
		int(screen.y / pixels_per_tile) / 2)
	rebuild()


func zoom_by(steps: float) -> void:
	var before := pixels_per_tile
	pixels_per_tile = clampf(pixels_per_tile + steps * SCALE_STEP, MIN_SCALE, MAX_SCALE)
	if is_equal_approx(before, pixels_per_tile):
		return
	# Zoom about the middle, so the place you were looking at stays put.
	var screen := _map_screen()
	var middle := origin + Vector2i(int(screen.x / before) / 2, int(screen.y / before) / 2)
	centre_on(middle)


func _on_picture_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return
	if _last_tiles.x <= 0 or _last_tiles.y <= 0 or _picture == null:
		return
	var extent := _picture.size
	if extent.x <= 0.0 or extent.y <= 0.0:
		return
	var local := Vector2i(
		int(clampf(floor(button.position.x / extent.x * _last_tiles.x),
			0.0, float(_last_tiles.x - 1))),
		int(clampf(floor(button.position.y / extent.y * _last_tiles.y),
			0.0, float(_last_tiles.y - 1))))
	var cell := origin + local
	var coord := GameWorld.chunk_of(cell)
	if not world.is_generated(coord) or not world.is_chunk_revealed(coord):
		_status.text = "No satellite data here — place a powered radar to scan this chunk."
		return
	view_requested.emit(cell)


func _process(_delta: float) -> void:
	if not visible:
		return
	_frames += 1
	# Apply a centre that was requested before the layout knew its real size,
	# once two frames have let the containers settle.
	if _pending_wait > 0:
		_pending_wait -= 1
		if _pending_wait == 0 and _pending_centre.x != 2147483647:
			var wanted := _pending_centre
			_pending_centre = Vector2i(2147483647, 2147483647)
			centre_on(wanted)
	_update_marker()
	# Ground only changes when the world does.  The old timer rebuilt the
	# whole map every tenth frame whether anything had changed or not.
	if _frames % REFRESH_FRAMES == 0 and world.revision != _last_revision:
		rebuild()


## Keep the blue square over the engineer as the map pans or zooms.
func _update_marker() -> void:
	if _marker == null or character == null or _last_tiles.x <= 0:
		if _marker != null:
			_marker.visible = false
		return
	var cell := character.cell()
	var local := Vector2(cell - origin)
	var screen := _picture.size
	var extent := Vector2(_last_tiles)
	var position := local * (screen / extent)
	_marker.visible = position.x >= 0.0 and position.y >= 0.0 \
		and position.x <= screen.x and position.y <= screen.y
	_marker.position = position - _marker.size * 0.5


func _gui_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_by(1.0)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_by(-1.0)
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var step := 8
		match (event as InputEventKey).keycode:
			KEY_LEFT: origin.x -= step
			KEY_RIGHT: origin.x += step
			KEY_UP: origin.y -= step
			KEY_DOWN: origin.y += step
			_: return
		rebuild()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			close_window()
			accept_event()


## The colours live in MapChunks now; this keeps the old call site working.
func build_colours() -> void:
	if _chunks == null and world != null:
		_chunks = MapChunks.new(world)


## Share the chunk picture cache with the minimap.
func set_map_chunks(chunks: MapChunks) -> void:
	if chunks != null:
		_chunks = chunks


func open_window(centre: Vector2i) -> void:
	visible = true
	build_colours()
	_pending_centre = centre
	_pending_wait = 2
	centre_on(centre)


func close_window() -> void:
	visible = false


func toggle(centre: Vector2i) -> void:
	if visible:
		close_window()
	else:
		open_window(centre)
