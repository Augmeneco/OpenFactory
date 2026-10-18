class_name MapGenerator
extends RefCounted
## Procedural terrain and ore generation.
##
## The shape of the map follows Factorio's Nauvis: an elevation field decides
## water and coastline, temperature and moisture pick between grass, dirt,
## desert and red desert, and ore comes in round patches laid out on a sparse
## jittered lattice — the same "spot noise" structure Factorio uses.
##
## Each cell belongs to the nearest patch that covers it, so different ore
## kinds never fight over ground and chunk seams cannot appear.
##
## Factorio drives this from its own noise-expression VM.  Reproducing that
## byte-for-byte needs the engine's private permutation tables, so this
## generator aims for a faithful look and feel with the map settings exposed
## under Factorio's own names.

## Ore kinds and their patch statistics.  ``spacing`` is the average distance
## between patch centres, ``radius`` the patch radius in tiles.
const ORE_TYPES := {
	"iron-ore":    {"spacing": 96.0,  "radius": 21.0, "amount": 620.0, "seed": 11},
	"copper-ore":  {"spacing": 96.0,  "radius": 21.0, "amount": 620.0, "seed": 22},
	"coal":        {"spacing": 88.0,  "radius": 19.0, "amount": 620.0, "seed": 33},
	"stone":       {"spacing": 104.0, "radius": 17.0, "amount": 520.0, "seed": 44},
	"uranium-ore": {"spacing": 340.0, "radius": 15.0, "amount": 480.0, "seed": 55},
	"crude-oil":   {"spacing": 190.0, "radius": 12.0, "amount": 300000.0, "seed": 66},
}

## How often a lattice site actually carries a patch.
const PATCH_DENSITY := 0.42

## Map settings, named after Factorio's own.
var water: float = 1.0
var terrain_segmentation: float = 1.0
var moisture: float = 1.0
var temperature: float = 1.0
var aux: float = 1.0
var ore_frequency: float = 1.0
var ore_size: float = 1.0
var ore_richness: float = 1.0
## Name -> {frequency, size, richness}; the world-settings dialog fills this
## per resource, while the three globals above stay as fallbacks.
var ore_settings: Dictionary = {}
## Multiplier for natural trees; the dryness slider drives this.
var tree_density: float = 1.0

var seed: int = 0

var _elevation: FastNoiseLite
var _elevation_detail: FastNoiseLite
var _moisture: FastNoiseLite
var _temperature: FastNoiseLite
var _aux: FastNoiseLite
var _detail: FastNoiseLite
## Forest patches used for natural trees.
var _forest: FastNoiseLite
## Factorio's own noise expressions, used for the fields that can be computed
## from the dump alone.  Built on first use because the VM parses 535
## expressions to construct.
var _expressions: NoiseExpression
## Map settings the expressions read through ``var('control:...')``.
var settings: Dictionary = {}
## Factorio's ``aux`` expression is closed over the data, so it replaces the
## generated auxiliary noise outright; the tests check that it varies.
var use_factorio_aux := true

var _ore_names: PackedStringArray = PackedStringArray()
var _ore_ids: Dictionary = {}

## The expression VM costs tens of microseconds per evaluation, and a chunk is
## 1024 cells: evaluating temperature and aux per cell took ~150 ms to generate
## one chunk, which is the hitch you feel while scrolling.  Both fields vary
## slowly (frequencies of 0.0035 and 0.0045 tiles^-1), so they are sampled on a
## coarse lattice and interpolated.  The exact per-cell functions below are
## kept for tests and tools.
const EXPR_SAMPLE_STEP := 16
var _temperature_samples: Dictionary = {}
var _aux_samples: Dictionary = {}


func _init(world_seed: int = 0) -> void:
	seed = world_seed
	ore_settings = default_ore_settings()
	_build_noise()
	_build_ore_palette()


static func default_ore_settings() -> Dictionary:
	var out: Dictionary = {}
	for ore_name: String in ORE_TYPES.keys():
		out[ore_name] = {"frequency": 1.0, "size": 1.0, "richness": 1.0}
	return out


## Apply the single-player world settings before the first chunk is generated.
func apply_settings(data: Dictionary) -> void:
	water = float(data.get("water", water))
	moisture = float(data.get("moisture", moisture))
	tree_density = float(data.get("tree_density", tree_density))
	ore_frequency = float(data.get("ore_frequency", ore_frequency))
	ore_size = float(data.get("ore_size", ore_size))
	ore_richness = float(data.get("ore_richness", ore_richness))
	var raw: Variant = data.get("ores", {})
	if raw is Dictionary:
		for ore_name: String in ORE_TYPES.keys():
			var entry: Variant = (raw as Dictionary).get(ore_name, null)
			if entry is Dictionary:
				var current: Dictionary = ore_settings.get(ore_name, {})
				current["frequency"] = float(entry.get("frequency",
					current.get("frequency", ore_frequency)))
				current["size"] = float(entry.get("size",
					current.get("size", ore_size)))
				current["richness"] = float(entry.get("richness",
					current.get("richness", ore_richness)))
				ore_settings[ore_name] = current


func ore_setting(ore_name: String, key: String) -> float:
	var entry: Variant = ore_settings.get(ore_name, null)
	if entry is Dictionary:
		return float((entry as Dictionary).get(key, 1.0))
	match key:
		"frequency":
			return ore_frequency
		"size":
			return ore_size
		"richness":
			return ore_richness
	return 1.0


## Temperature and auxiliary noise from Factorio's own expressions.
##
## The dump carries every expression, and these two evaluate to real numbers
## from it — the test checks that they vary and stay in range.  Elevation and
## moisture cannot: ``elevation_nauvis_function`` reads ``wlc_elevation`` and
## ``start_lake``, and ``moisture_nauvis`` reads ``moisture_main``, all three of
## which the engine supplies per position and the dump does not carry.  Those
## two stay on the generated noise.
func factorio_temperature(cell: Vector2i) -> float:
	return expressions().evaluate("temperature", float(cell.x), float(cell.y),
		seed, settings)


func factorio_aux(cell: Vector2i) -> float:
	return expressions().evaluate("aux", float(cell.x), float(cell.y), seed,
		settings)


## Bilinear sample of a named expression from the coarse lattice.
func _sampled_expression(name: String, cell: Vector2i,
		cache: Dictionary) -> float:
	var step := EXPR_SAMPLE_STEP
	var fx := float(cell.x) / float(step)
	var fy := float(cell.y) / float(step)
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var v00 := _lattice_value(name, Vector2i(x0, y0), cache)
	var v10 := _lattice_value(name, Vector2i(x0 + 1, y0), cache)
	var v01 := _lattice_value(name, Vector2i(x0, y0 + 1), cache)
	var v11 := _lattice_value(name, Vector2i(x0 + 1, y0 + 1), cache)
	return lerpf(lerpf(v00, v10, tx), lerpf(v01, v11, tx), ty)


func _lattice_value(name: String, lattice: Vector2i, cache: Dictionary) -> float:
	var hit: Variant = cache.get(lattice)
	if hit != null:
		return float(hit)
	var value := expressions().evaluate(name,
		float(lattice.x * EXPR_SAMPLE_STEP), float(lattice.y * EXPR_SAMPLE_STEP),
		seed, settings)
	cache[lattice] = value
	return value


## Temperature for terrain decisions, interpolated from the coarse lattice.
func sampled_temperature(cell: Vector2i) -> float:
	return _sampled_expression("temperature", cell, _temperature_samples)


## Auxiliary variant field, interpolated from the coarse lattice.
func sampled_aux(cell: Vector2i) -> float:
	return _sampled_expression("aux", cell, _aux_samples)


func _build_noise() -> void:
	_elevation = _noise(seed, 0.0028, 5, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	_elevation_detail = _noise(seed + 1, 0.0125, 3, FastNoiseLite.TYPE_SIMPLEX)
	_moisture = _noise(seed + 2, 0.0065, 3, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	_temperature = _noise(seed + 3, 0.0035, 2, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	_aux = _noise(seed + 4, 0.0045, 2, FastNoiseLite.TYPE_SIMPLEX)
	if settings.is_empty():
		settings = default_settings()
	_detail = _noise(seed + 5, 0.055, 2, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
	_forest = _noise(seed + 6, 0.018, 3, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)


## The expression VM, built once on demand.
func expressions() -> NoiseExpression:
	if _expressions == null:
		_expressions = NoiseExpression.new()
	return _expressions


## Default map settings, which is what an unmodified freeplay map uses.
static func default_settings() -> Dictionary:
	return {
		"control:temperature:bias": 0.0,
		"control:temperature:frequency": 1.0,
		"control:moisture:bias": 0.0,
		"control:moisture:frequency": 1.0,
		"control:aux:bias": 0.0,
		"control:aux:frequency": 1.0,
		"control:water:frequency": 1.0,
		"control:water:size": 1.0,
	}


static func _noise(nseed: int, frequency: float, octaves: int,
		noise_type: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = noise_type
	n.seed = nseed
	n.frequency = frequency
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	n.fractal_gain = 0.5
	n.fractal_lacunarity = 2.0
	return n


func _build_ore_palette() -> void:
	for ore_name: String in ["iron-ore", "copper-ore", "coal", "stone",
			"uranium-ore", "crude-oil"]:
		if Prototypes.get_p("resource", ore_name).is_empty():
			continue
		_ore_ids[ore_name] = _ore_names.size() + 1
		_ore_names.append(ore_name)


func ore_id(ore_name: String) -> int:
	return int(_ore_ids.get(ore_name, 0))


func ore_name(ore_id: int) -> String:
	var index := ore_id - 1
	if index < 0 or index >= _ore_names.size():
		return ""
	return _ore_names[index]


func ore_names() -> PackedStringArray:
	return _ore_names


## Depletion stage (0 = full, 7 = almost gone) used to pick the ore picture.
func ore_stage(ore_name: String, amount: float) -> int:
	var spec: Variant = ORE_TYPES.get(ore_name)
	if spec == null:
		return 0
	var full: float = float(spec["amount"]) * maxf(ore_setting(ore_name, "richness"), 0.05)
	var fraction := clampf(amount / maxf(full, 1.0), 0.0, 1.0)
	return clampi(7 - int(round(fraction * 7.0)), 0, 7)


# --------------------------------------------------------------------------
# chunk filling
# --------------------------------------------------------------------------

func fill_chunk(world: GameWorld, coord: Vector2i, chunk: GameWorld.Chunk) -> void:
	var base := coord * GameWorld.CHUNK

	for y in GameWorld.CHUNK:
		for x in GameWorld.CHUNK:
			var cell := base + Vector2i(x, y)
			var tile := tile_for(cell)
			chunk.tiles[y * GameWorld.CHUNK + x] = world.tile_id(tile)

	_paint_ore(world, chunk, base)
	_spawn_decoratives(world, coord, base)


## Tile name for a world cell, without touching the chunk cache.
func tile_for(cell: Vector2i) -> String:
	var ex := float(cell.x)
	var ey := float(cell.y)
	var e := _elevation.get_noise_2d(ex, ey) * 1.35
	e += _elevation_detail.get_noise_2d(ex, ey) * 0.18
	e *= terrain_segmentation

	var water_tile := _classify_elevation(e * water)
	if not water_tile.is_empty():
		return water_tile

	# Factorio's ``moisture`` cannot be evaluated — ``moisture_nauvis`` reads
	# ``moisture_main``, which the engine supplies and the dump does not — so
	# the wetness field stays on generated noise.  ``temperature`` and ``aux``
	# are closed over the data, so they come from the expressions: temperature
	# in degrees Celsius between -20 and 50, normalised around the 15 C sea
	# level, and aux as the variant field below.
	var m := _moisture.get_noise_2d(ex, ey) * moisture
	# Temperature is Factorio's own expression, in degrees Celsius clamped to
	# -20..50, normalised around the 15 C sea level it sits at on Nauvis.
	var t := (sampled_temperature(cell) - 15.0) / 35.0 * temperature
	return _land_tile(cell, e, m, t)


## Returns a water tile name, or "" when the cell is land.
func _classify_elevation(e: float) -> String:
	if e < -0.34:
		return "deepwater"
	if e < -0.22:
		return "water"
	if e < -0.17:
		return "water-shallow"
	return ""


func _land_tile(cell: Vector2i, e: float, m: float, t: float) -> String:
	# Beaches hug the coastline.
	if e < -0.11:
		return _variant_of(cell, ["sand-1", "sand-1", "sand-2", "sand-3"], 101)

	# Hot and dry turns into desert; very hot into red desert.
	if t > 0.34 and m < 0.08:
		return _variant_of(cell, ["red-desert-0", "red-desert-1", "red-desert-2",
			"red-desert-3"], 202)
	if t > 0.12 and m < -0.14:
		return _variant_of(cell, ["sand-1", "sand-2", "dry-dirt", "sand-3"], 203)

	# Wet lowlands are grass; drier ground fades through dirt.
	if m > 0.22:
		return _variant_of(cell, ["grass-1", "grass-2", "grass-3", "grass-4"], 301)
	if m > 0.02:
		return _variant_of(cell, ["grass-1", "grass-3", "dirt-1", "grass-2", "dirt-2"], 302)
	if m > -0.16:
		return _variant_of(cell, ["dirt-1", "dirt-2", "grass-3", "dirt-3", "dirt-4"], 303)
	if m > -0.34:
		return _variant_of(cell, ["dirt-3", "dirt-4", "dirt-5", "dry-dirt"], 304)
	return _variant_of(cell, ["dry-dirt", "dirt-5", "dirt-6", "dirt-7"], 305)


## Which of a tile's variants to draw.
##
## The variant comes from a mid-frequency field rather than a per-tile hash, so
## grass and dirt form patches instead of a checkerboard — and Factorio's own
## ``aux`` expression is what the game uses to break those patches up, so it is
## mixed in here.
## Which of a tile's variants to draw.
##
## The variant comes from a mid-frequency field rather than a per-tile hash, so
## grass and dirt form patches instead of a checkerboard — and Factorio's own
## ``aux`` expression is what the game breaks those patches up with, so it is
## mixed in here.
func _variant_of(cell: Vector2i, options: Array, salt: int) -> String:
	var n := _detail.get_noise_2d(float(cell.x), float(cell.y))
	var aux := sampled_aux(cell) if use_factorio_aux else 0.5
	var roll := fposmod(n * 0.35 + aux * 0.3 + float(posmod(salt, 977)) * 0.017,
		1.0)
	return str(options[int(roll * options.size()) % options.size()])


# --------------------------------------------------------------------------
# natural decoratives
# --------------------------------------------------------------------------

const FOREST_TREES := ["tree-01", "tree-02", "tree-03", "tree-04",
	"tree-05", "tree-06", "tree-07", "tree-08", "tree-09"]
const DRY_TREES := ["dry-tree", "dead-tree-desert", "dead-grey-trunk",
	"dead-dry-hairy-tree", "dry-hairy-tree"]


## Trees and rocks are entities, so they must be placed while the chunk is
## being filled.  Only land is eligible: every occupied cell is checked for
## water, ore and other entities before the entity is placed.
func _spawn_decoratives(world: GameWorld, coord: Vector2i, base: Vector2i) -> void:
	for y in range(1, GameWorld.CHUNK - 1):
		for x in range(1, GameWorld.CHUNK - 1):
			var cell := base + Vector2i(x, y)
			var tile := world.tile_at(cell)
			if _is_water(tile):
				continue
			if not str(world.ore_at(cell)["name"]).is_empty():
				continue
			var forest := clampf((_forest.get_noise_2d(float(cell.x), float(cell.y))
				+ 1.0) * 0.5, 0.0, 1.0)
			var tree_roll := hash01(cell, 9101 + seed % 100003)
			if tree_roll < _tree_chance(tile, forest):
				var tree_name := _tree_name(tile, cell)
				var tree := Entity.create("tree", tree_name, cell)
				if _can_spawn_decorative(world, tree, coord):
					world.place_entity(tree)
				continue
			var rock_roll := hash01(cell, 9202 + seed % 100003)
			if rock_roll >= _rock_chance(tile):
				continue
			var rock_name := _rock_name(tile, cell)
			var rock := Entity.create("simple-entity", rock_name, cell)
			if _can_spawn_decorative(world, rock, coord):
				world.place_entity(rock)


func _tree_chance(tile: String, forest: float) -> float:
	var base := 0.0
	if tile.begins_with("grass"):
		base = 0.006
	elif tile.begins_with("dirt"):
		base = 0.004
	elif tile.begins_with("dry-dirt"):
		base = 0.002
	elif tile.begins_with("sand") or tile.begins_with("red-desert"):
		base = 0.0008
	# Forest patches: above ~0.5 the tree density climbs sharply, below it
	# only isolated trees appear.
	return (base + maxf(0.0, forest - 0.48) * 0.55) * maxf(tree_density, 0.0)


func _tree_name(tile: String, cell: Vector2i) -> String:
	var options: Array = FOREST_TREES
	if tile.begins_with("sand") or tile.begins_with("red-desert") \
			or tile.begins_with("dry-dirt"):
		options = DRY_TREES
	var index := int(hash01(cell, 9303 + seed % 100003) * float(options.size()))
	return str(options[clampi(index, 0, options.size() - 1)])


func _rock_chance(tile: String) -> float:
	if tile.begins_with("sand") or tile.begins_with("red-desert"):
		return 0.0045
	if tile.begins_with("dry-dirt"):
		return 0.0035
	if tile.begins_with("grass") or tile.begins_with("dirt"):
		return 0.0028
	return 0.0


func _rock_name(tile: String, cell: Vector2i) -> String:
	if tile.begins_with("sand") or tile.begins_with("red-desert"):
		return "big-sand-rock"
	var roll := hash01(cell, 9404 + seed % 100003)
	if roll < 0.08:
		return "huge-rock"
	return "big-rock"


func _can_spawn_decorative(world: GameWorld, entity: Entity,
		coord: Vector2i) -> bool:
	for cell: Vector2i in entity.occupied_cells():
		if GameWorld.chunk_of(cell) != coord:
			return false
		var tile := world.tile_at(cell)
		if _is_water(tile):
			return false
		if not str(world.ore_at(cell)["name"]).is_empty():
			return false
		if world.entity_at(cell) != null:
			return false
	return true


# --------------------------------------------------------------------------
# ore
# --------------------------------------------------------------------------

## Every ore patch whose area could reach the chunk starting at ``base``.
func patches_near(base: Vector2i) -> Array:
	var out: Array = []
	var chunk_end := base + Vector2i(GameWorld.CHUNK, GameWorld.CHUNK)
	for ore: String in _ore_names:
		var spec: Dictionary = ORE_TYPES[ore]
		var frequency := maxf(ore_setting(ore, "frequency"), 0.05)
		var spacing: float = float(spec["spacing"]) / frequency
		var radius: float = float(spec["radius"]) * ore_setting(ore, "size")
		var base_amount: float = float(spec["amount"]) * ore_setting(ore, "richness")
		var salt: int = int(spec["seed"])
		var reach := radius * 1.3 + 2.0

		var min_x := int(floor((base.x - reach) / spacing))
		var max_x := int(floor((chunk_end.x + reach) / spacing))
		var min_y := int(floor((base.y - reach) / spacing))
		var max_y := int(floor((chunk_end.y + reach) / spacing))

		for cy in range(min_y, max_y + 1):
			for cx in range(min_x, max_x + 1):
				var patch_cell := Vector2i(cx, cy)
				var rng := _patch_rng(patch_cell, salt)
				if rng.randf() > PATCH_DENSITY:
					continue
				var center := Vector2(patch_cell) * spacing \
					+ Vector2(rng.randf_range(0.15, 0.85), rng.randf_range(0.15, 0.85)) * spacing
				var this_radius := radius * rng.randf_range(0.75, 1.25)
				var amount := base_amount * rng.randf_range(0.7, 1.3)
				if center.x + this_radius < base.x or center.x - this_radius > chunk_end.x:
					continue
				if center.y + this_radius < base.y or center.y - this_radius > chunk_end.y:
					continue
				out.append({
					"ore": ore,
					"center": center,
					"radius": this_radius,
					"amount": amount,
					"salt": salt ^ (cx * 73856093) ^ (cy * 19349663),
				})
	return out


## Assign every land cell to the nearest patch covering it.
func _paint_ore(world: GameWorld, chunk: GameWorld.Chunk, base: Vector2i) -> void:
	var patches := patches_near(base)
	if patches.is_empty():
		return
	for y in GameWorld.CHUNK:
		for x in GameWorld.CHUNK:
			var idx := y * GameWorld.CHUNK + x
			var tile := world.tile_name(chunk.tiles[idx])
			if _is_water(tile):
				continue
			var cell := base + Vector2i(x, y)
			var position := Vector2(cell) + Vector2(0.5, 0.5)

			var best_ore := ""
			var best_amount := 0.0
			var best_score := INF
			for patch: Dictionary in patches:
				var edge := hash01(Vector2i(cell.x >> 1, cell.y >> 1),
					int(patch["salt"]))
				var effective: float = float(patch["radius"]) * (0.80 + 0.40 * edge)
				var distance := position.distance_to(patch["center"])
				if distance > effective:
					continue
				var score := distance / effective
				if score < best_score:
					best_score = score
					best_ore = str(patch["ore"])
					var falloff := 1.0 - score * score
					best_amount = float(patch["amount"]) * (0.35 + 0.65 * falloff) \
						* lerpf(0.7, 1.15, hash01(cell, 7))
			if best_ore.is_empty():
				continue
			chunk.ore[idx] = ore_id(best_ore)
			chunk.amount[idx] = snappedf(maxf(best_amount, 1.0), 1.0)


func _is_water(tile: String) -> bool:
	return tile.begins_with("water") or tile.begins_with("deepwater")


func _patch_rng(patch_cell: Vector2i, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(patch_cell.x, patch_cell.y, salt)) ^ (seed * 2654435761)
	return rng


# --------------------------------------------------------------------------
# hashing helpers
# --------------------------------------------------------------------------

static func hash01(cell: Vector2i, salt: int) -> float:
	var h := int(cell.x) * 0x1f1f1f1f ^ int(cell.y) * 0x27d4eb2d ^ salt
	h = (h ^ (h >> 15)) * 0x2545f491
	h = h ^ (h >> 13)
	return float(h & 0xffffff) / 16777216.0
