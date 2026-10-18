class_name NoiseBasis
extends RefCounted
## The noise primitives Factorio's expressions are built on.
##
## Factorio defines its 48 named noise functions in Lua, on top of a handful of
## primitives the engine supplies: ``basis_noise``, ``multioctave_noise``,
## ``quick_multioctave_noise``, ``spot_noise`` and the voronoi family.  Those
## are implemented here.
##
## The engine's own hash is C++ and not in the data, so the basis here is an
## independent gradient noise.  The *structure* is Factorio's — same
## frequencies, same octave multipliers, same offsets, same combinations — so a
## map has the same shape and the same biome rules, but a given seed does not
## reproduce the original tile for tile.  That is stated plainly in the README.


## Hash of an integer lattice point and a seed, in [-1, 1].
static func _hash2(x: int, y: int, seed_value: int) -> float:
	var h := x * 374761393 + y * 668265263 + seed_value * 1442695040888963407
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / float(0x800000) - 1.0


## Gradient of a lattice point: two components in [-1, 1].
static func _gradient(x: int, y: int, seed_value: int) -> Vector2:
	var angle := _hash2(x, y, seed_value) * PI
	return Vector2(cos(angle), sin(angle))


## One octave of gradient noise, in roughly [-1, 1] before ``output_scale``.
##
## This is Factorio's ``basis_noise``: a smooth field sampled at
## ``(x * input_scale + offset_x, y * input_scale + offset_y)``.
static func basis_noise(x: float, y: float, seed_value: int, input_scale: float,
		output_scale := 1.0, offset_x := 0.0, offset_y := 0.0) -> float:
	var scale := input_scale if input_scale != 0.0 else 1.0
	var px := x * scale + offset_x
	var py := y * scale + offset_y
	var x0 := int(floor(px))
	var y0 := int(floor(py))
	var fx := px - float(x0)
	var fy := py - float(y0)

	# Quintic fade, the usual choice for gradient noise.
	var u := fx * fx * fx * (fx * (fx * 6.0 - 15.0) + 10.0)
	var v := fy * fy * fy * (fy * (fy * 6.0 - 15.0) + 10.0)

	var g00 := _gradient(x0, y0, seed_value)
	var g10 := _gradient(x0 + 1, y0, seed_value)
	var g01 := _gradient(x0, y0 + 1, seed_value)
	var g11 := _gradient(x0 + 1, y0 + 1, seed_value)

	var n00 := g00.dot(Vector2(fx, fy))
	var n10 := g10.dot(Vector2(fx - 1.0, fy))
	var n01 := g01.dot(Vector2(fx, fy - 1.0))
	var n11 := g11.dot(Vector2(fx - 1.0, fy - 1.0))

	var top := lerpf(n00, n10, u)
	var bottom := lerpf(n01, n11, u)
	return lerpf(top, bottom, v) * 2.0 * output_scale


## Several octaves of ``basis_noise`` added together.
##
## ``octave_input_scale_multiplier`` and ``octave_output_scale_multiplier``
## come straight from the expression; Factorio defaults both to 0.5.
static func multioctave_noise(x: float, y: float, seed0: int, seed1: int,
		octaves: int, input_scale: float, output_scale: float,
		offset_x := 0.0, offset_y := 0.0,
		octave_input_scale_multiplier := 0.5,
		octave_output_scale_multiplier := 0.5,
		octave_seed_0_offset := 0) -> float:
	var total := 0.0
	var amplitude := 1.0
	var frequency := input_scale
	var normaliser := 0.0
	for octave in maxi(1, octaves):
		var seed_value := seed0 + octave_seed_0_offset * octave
		total += basis_noise(x, y, _mix(seed_value, seed1 + octave), frequency,
			output_scale, offset_x, offset_y) * amplitude
		normaliser += amplitude
		amplitude *= octave_output_scale_multiplier
		frequency *= octave_input_scale_multiplier
	if normaliser <= 0.0:
		return 0.0
	return total / normaliser


## ``variable_persistence_multioctave_noise``: like the plain one, but each
## octave's amplitude follows a persistence curve rather than a fixed ratio.
static func variable_persistence_noise(x: float, y: float, seed0: int, seed1: int,
		octaves: int, input_scale: float, output_scale: float,
		persistence: float, offset_x := 0.0, offset_y := 0.0) -> float:
	var total := 0.0
	var amplitude := 1.0
	var frequency := input_scale
	var normaliser := 0.0
	for octave in maxi(1, octaves):
		total += basis_noise(x, y, _mix(seed0, seed1 + octave), frequency,
			output_scale, offset_x, offset_y) * amplitude
		normaliser += amplitude
		amplitude *= clampf(persistence, 0.05, 1.0)
		frequency *= 0.5
	if normaliser <= 0.0:
		return 0.0
	return total / normaliser


static func _mix(a: int, b: int) -> int:
	return a * 31 + b * 131 + 0x9E3779B9


## Deterministic pseudo-random number in [0, 1) for a lattice cell.
static func cell_random(x: int, y: int, seed_value: int) -> float:
	return (_hash2(x, y, seed_value) + 1.0) * 0.5


static func cell_random_range(x: int, y: int, seed_value: int, low: float,
		high: float) -> float:
	return low + cell_random(x, y, seed_value) * (high - low)


## ``spot_noise``: scattered blobs on a lattice of candidate points.
##
## A region is divided into ``region_size`` cells; each cell rolls
## ``candidate_point_count`` candidates and the nearest one whose quantity roll
## beats the density expression contributes a blob at ``spot_radius``.
static func spot_noise(x: float, y: float, seed0: int, seed1: int,
		region_size: float, candidate_point_count: int,
		spot_quantity: float, spot_radius: float, density: float) -> float:
	if spot_radius <= 0.0 or density <= 0.0:
		return 0.0
	var cell_x := int(floor(x / region_size))
	var cell_y := int(floor(y / region_size))
	var best := 0.0
	# The neighbouring cells are checked too, so a blob near an edge is not
	# cut off.
	for offset_y in range(-1, 2):
		for offset_x in range(-1, 2):
			var cx := cell_x + offset_x
			var cy := cell_y + offset_y
			for candidate in maxi(1, candidate_point_count):
				var salt := _mix(cx, cy) + candidate * 7919
				if cell_random(cx * 31 + candidate, cy * 17 + candidate, salt) > density:
					continue
				var point := Vector2(
					(float(cx) + cell_random(cx + candidate, cy, salt)) * region_size,
					(float(cy) + cell_random(cx, cy + candidate,
						_mix(salt, 5))) * region_size)
				var distance := Vector2(x, y).distance_to(point)
				if distance > spot_radius:
					continue
				var falloff := 1.0 - distance / spot_radius
				best = maxf(best, falloff * spot_quantity)
	return best


## ``voronoi_cell_id``: which cell of a jittered lattice a point falls in.
static func voronoi_cell_id(x: float, y: float, seed0: int, seed1: int,
		grid_size: float, jitter := 1.0) -> float:
	if grid_size <= 0.0:
		return 0.0
	var cell_x := int(floor(x / grid_size))
	var cell_y := int(floor(y / grid_size))
	var best_distance := INF
	var best_id := 0.0
	for offset_y in range(-1, 2):
		for offset_x in range(-1, 2):
			var cx := cell_x + offset_x
			var cy := cell_y + offset_y
			var salt := _mix(cx, cy) + seed1
			var point := Vector2((float(cx) + 0.5
					+ (cell_random(cx, cy, salt) - 0.5) * jitter) * grid_size,
				(float(cy) + 0.5 + (cell_random(cx, cy, _mix(salt, 3)) - 0.5)
					* jitter) * grid_size)
			var distance := Vector2(x, y).distance_squared_to(point)
			if distance < best_distance:
				best_distance = distance
				best_id = float(_mix(cx + seed0, cy))
	return absf(fmod(best_id, 100000.0))
