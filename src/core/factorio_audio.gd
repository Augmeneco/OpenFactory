extends Node
## Factorio's own sounds, read from the installation and played by distance.
##
## There are 4391 `.ogg` files in the install, and almost none of them are
## referred to by the machine that makes the noise: a furnace has no sound of
## its own, it uses the `build_small` and `axe_mining_stone` entries of the
## `utility-sounds` prototype.  So this service resolves two kinds of thing —
## a named utility sound, and a sound dictionary straight off a prototype — and
## plays either of them.
##
## Everything is positional in the only sense a top-down game needs: a sound
## has a world position, the listener is the camera, and the volume falls off
## with the distance between them.

## How many sounds can be in the air at once.  Factorio caps working sounds per
## prototype; a single global cap is simpler and does the same job.
const MAX_PLAYERS := 24
## Background soundtrack volume and crossfade time.
const MUSIC_DB := -10.0
const MUSIC_FADE_SECONDS := 2.5
## Factorio ships its soundtrack under ``__base__/sound/ambient``.  The menu
## has one theme; the factory grows through early, mid and late playlists.
const MUSIC_ROOT := "__base__/sound/ambient/"
const MUSIC_TRACKS := {
	"menu": ["main-menu.ogg"],
	"early": ["after-the-crash.ogg", "first-light.ogg", "automation.ogg"],
	"mid": ["the-search-for-iron.ogg", "gathering-horizon.ogg",
		"research-and-minerals.ogg"],
	"late": ["the-oil-industry.ogg", "expansion.ogg",
		"beyond-factory-outskirts.ogg", "turbine-dynamics.ogg"],
}
## At this distance a sound is inaudible and is not started at all.
const SILENT_DISTANCE := 55.0
## Working sounds are the expensive ones, so only the nearest few run.
const MAX_LOOPS := 8

var enabled := true
## Where the player is looking, in tiles.  The game sets this each frame.
var listener := Vector2.ZERO
## Positional effects and interface clicks.
var master_volume := 0.9
## Background soundtrack, independent from the effects volume.
var music_volume := 0.85

var _cache: Dictionary = {}          ## path -> AudioStream, or null when it failed
var _players: Array = []             ## a fixed pool of AudioStreamPlayer
var _busy: Array = []                ## player index -> ticks it stays claimed
var _loops: Dictionary = {}          ## key -> { player, position, reference, volume }
var _played := 0
var _missing: Dictionary = {}
## The active soundtrack context (``menu``/``early``/``mid``/``late``).
var music_context := ""
## The file name of the track currently playing, for diagnostics.
var music_track := ""
var _music_players: Array = []
var _music_active := 0
var _music_started := false
var _music_fade_from: AudioStreamPlayer = null
var _music_fade_old_db := 0.0
var _music_fade_t := 0.0
var _music_fade_duration := MUSIC_FADE_SECONDS


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_music_bus()
	for _index in MAX_PLAYERS:
		var player := AudioStreamPlayer.new()
		player.bus = "Master"
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(player)
		_players.append(player)
		_busy.append(0)
	# Two music players are enough for a crossfade.
	for index in 2:
		var music := AudioStreamPlayer.new()
		music.bus = "Music"
		music.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(music)
		music.finished.connect(_on_music_finished.bind(music, index))
		_music_players.append(music)


func _process(delta: float) -> void:
	_update_music(delta)


func _setup_music_bus() -> void:
	if AudioServer.get_bus_index("Music") >= 0:
		return
	AudioServer.add_bus()
	var index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, "Music")
	AudioServer.set_bus_send(index, "Master")
	AudioServer.set_bus_volume_db(index, -3.0)


func stats() -> Dictionary:
	var loaded := 0
	for value: Variant in _cache.values():
		if value != null:
			loaded += 1
	return {
		"played": _played, "loaded": loaded, "loops": _loops.size(),
		"missing": _missing.size(), "enabled": enabled,
		"music_context": music_context, "music_track": music_track,
		"master_volume": master_volume, "music_volume": music_volume,
	}


# --------------------------------------------------------------------------
# resolution
# --------------------------------------------------------------------------

## A named entry from the `utility-sounds` prototype, which is where almost
## every noise the interface makes actually lives.
func utility_sound(name: String) -> Variant:
	var sounds := Prototypes.get_p("utility-sounds", "default")
	if sounds.is_empty():
		return null
	return sounds.get(name)


## Flatten whatever shape the data uses into ``{ path, volume }``.
##
## A sound can be a bare filename, a list of alternative filenames, a
## dictionary with a volume, a dictionary of `variations`, or a dictionary with
## the whole thing nested under `sound`.  All of them turn up in the dump, and
## a caller should not have to care which.
func resolve(reference: Variant, depth := 0) -> Dictionary:
	if reference == null or depth > 4:
		return {}
	if reference is String:
		var text := str(reference)
		return {"path": text, "volume": 1.0} if not text.is_empty() else {}
	if reference is Array:
		var list: Array = reference
		if list.is_empty():
			return {}
		return resolve(list[randi() % list.size()], depth + 1)
	if not (reference is Dictionary):
		return {}
	var entry: Dictionary = reference
	if entry.has("variations"):
		var variations: Variant = entry["variations"]
		if variations is Array and not (variations as Array).is_empty():
			var picked := resolve((variations as Array)[randi()
				% (variations as Array).size()], depth + 1)
			if not picked.is_empty():
				# A volume on the wrapper scales the variation's own.
				picked["volume"] = float(picked.get("volume", 1.0)) \
					* float(entry.get("volume", 1.0))
			return picked
	if entry.has("sound"):
		return resolve(entry["sound"], depth + 1)
	if entry.has("filename"):
		var filename: Variant = entry["filename"]
		if filename is Array:
			var names: Array = filename
			if names.is_empty():
				return {}
			filename = names[randi() % names.size()]
		var path := str(filename)
		if path.is_empty():
			return {}
		return {"path": path, "volume": float(entry.get("volume", 1.0))}
	return {}


## The decoded stream for a reference, or ``null``.  Loaded once and kept: a
## belt's build sound is asked for every time the player lays one.
func stream_for(reference: Variant) -> AudioStream:
	var picked := resolve(reference)
	if picked.is_empty():
		return null
	return stream_at(str(picked["path"]))


func stream_at(reference_path: String) -> AudioStream:
	if _cache.has(reference_path):
		return _cache[reference_path]
	var stream: AudioStream = null
	var path := FactorioAssets.resolve(reference_path)
	var source := FactorioAssets.packed_file(path)
	if not source.is_empty():
		# Factorio ships Ogg Vorbis, which Godot decodes itself.  A bundled
		# export stores the file inside the PCK, where load_from_file cannot
		# open it; decode the FileAccess bytes instead.
		if source.begins_with("res://") or source.begins_with("user://"):
			var bytes := FileAccess.get_file_as_bytes(source)
			if not bytes.is_empty():
				stream = AudioStreamOggVorbis.load_from_buffer(bytes)
		else:
			stream = AudioStreamOggVorbis.load_from_file(source)
	if stream == null:
		_missing[reference_path] = true
	_cache[reference_path] = stream
	return stream


func has_sound(reference: Variant) -> bool:
	return not resolve(reference).is_empty()


# --------------------------------------------------------------------------
# playback
# --------------------------------------------------------------------------

## How much a sound at a world position is quietened, in decibels.
func falloff(position: Vector2) -> float:
	var distance := listener.distance_to(position)
	if distance >= SILENT_DISTANCE:
		return -80.0
	# A gentle curve rather than a hard cutoff, so approaching machines swell.
	var closeness := 1.0 - distance / SILENT_DISTANCE
	return linear_to_db(maxf(0.0001, closeness * closeness))


## Play a one-shot at a world position, if it is close enough to be heard.
func play_at(reference: Variant, position: Vector2, extra_db := 0.0,
		pitch := 1.0) -> bool:
	if not enabled:
		return false
	if listener.distance_to(position) >= SILENT_DISTANCE:
		return false
	var picked := resolve(reference)
	if picked.is_empty():
		return false
	var stream := stream_at(str(picked["path"]))
	if stream == null:
		return false
	var player := _free_player()
	if player == null:
		return false
	player.stream = stream
	player.pitch_scale = pitch
	player.volume_db = linear_to_db(maxf(0.0001, float(picked["volume"])
		* master_volume)) + falloff(position) + extra_db
	player.play()
	_played += 1
	return true


## A named utility sound, played at a world position.
func play_utility(name: String, position: Vector2, extra_db := 0.0,
		pitch := 1.0) -> bool:
	return play_at(utility_sound(name), position, extra_db, pitch)


## Start or move a looping sound, keyed by whatever owns it.
##
## The nearest loops win: when more than `MAX_LOOPS` are wanted, the one
## furthest from the camera gives up its player.  That is what keeps a bank of
## forty furnaces from turning into noise.
func loop_at(key: String, reference: Variant, position: Vector2,
		extra_db := 0.0) -> bool:
	if not enabled:
		return false
	var picked := resolve(reference)
	if picked.is_empty():
		return false
	var existing: Variant = _loops.get(key)
	if existing is Dictionary:
		# Already running: follow it and re-level it.
		var entry: Dictionary = existing
		entry["position"] = position
		var player: AudioStreamPlayer = entry["player"]
		player.volume_db = linear_to_db(maxf(0.0001, float(picked["volume"])
			* master_volume)) + falloff(position) + extra_db
		return true
	if _loops.size() >= MAX_LOOPS and not _evict_furthest(position):
		return false
	var stream := stream_at(str(picked["path"]))
	if stream == null:
		return false
	# An Ogg stream only repeats if it is told to.
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	var player := _free_player()
	if player == null:
		return false
	player.stream = stream
	player.pitch_scale = 1.0
	player.volume_db = linear_to_db(maxf(0.0001, float(picked["volume"])
		* master_volume)) + falloff(position) + extra_db
	player.play()
	_loops[key] = {"player": player, "position": position,
		"reference": reference, "volume": extra_db}
	return true


## Give up the loop furthest away to make room, if the newcomer is nearer.
func _evict_furthest(position: Vector2) -> bool:
	var worst_key := ""
	var worst_distance := listener.distance_to(position)
	for key: String in _loops:
		var entry: Dictionary = _loops[key]
		var distance := listener.distance_to(Vector2(entry["position"]))
		if distance > worst_distance:
			worst_distance = distance
			worst_key = key
	if worst_key.is_empty():
		return false
	stop_loop(worst_key)
	return true


func stop_loop(key: String) -> void:
	var entry: Variant = _loops.get(key)
	if not (entry is Dictionary):
		return
	var player: AudioStreamPlayer = (entry as Dictionary)["player"]
	player.stop()
	player.stream = null
	_loops.erase(key)


## Stop every loop that was not touched this frame, which is how machines that
## have stopped or gone off screen fall silent.
func retire_loops(seen: Dictionary) -> void:
	for key: String in _loops.keys():
		if not seen.has(key):
			stop_loop(key)


## Tell the soundtrack service which playlist should be playing.
##
## The game calls this with ``menu`` while the title screen is open and with an
## era (``early``/``mid``/``late``) in game.  A change crossfades immediately
## so the menu theme does not keep playing behind the first factory.
func set_music_context(context: String) -> void:
	if not MUSIC_TRACKS.has(context):
		return
	if context == music_context:
		if not _music_started or music_track.is_empty():
			_music_play_next()
		return
	music_context = context
	_music_play_next()


## Advance to a random track in the current playlist (never the same one twice
## when there is a choice).  Missing tracks are skipped.
func _music_play_next() -> void:
	var tracks: Array = MUSIC_TRACKS.get(music_context, [])
	if tracks.is_empty():
		return
	var attempts := tracks.size()
	var start := randi() % attempts
	for step in attempts:
		var relative := str(tracks[(start + step) % attempts])
		if attempts > 1 and relative == music_track:
			continue
		var stream := stream_at(MUSIC_ROOT + relative)
		if stream == null:
			continue
		_start_music_stream(stream, relative)
		return


func _start_music_stream(stream: AudioStream, relative: String) -> void:
	var old: AudioStreamPlayer = null
	if _music_started:
		old = _music_players[_music_active]
	var next_index := 1 - _music_active
	var next: AudioStreamPlayer = _music_players[next_index]
	next.stream = stream
	# Soundtrack tracks are one-shot; the finished signal selects the next.
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = false
	next.volume_db = -60.0 if old != null else _music_target_db()
	next.play()
	_music_active = next_index
	_music_started = true
	music_track = relative
	if old != null:
		# If another context change interrupted a previous crossfade, stop the
		# already-fading player instead of leaving it playing forever.
		if _music_fade_from != null and is_instance_valid(_music_fade_from) \
				and _music_fade_from != old:
			_music_fade_from.stop()
			_music_fade_from.stream = null
		_music_fade_from = old
		_music_fade_old_db = old.volume_db
		_music_fade_t = 0.0
		_music_fade_duration = MUSIC_FADE_SECONDS
	else:
		_music_fade_from = null
		_music_fade_t = 1.0
		_music_fade_duration = MUSIC_FADE_SECONDS


func _update_music(delta: float) -> void:
	if not _music_started or _music_players.is_empty():
		return
	var active: AudioStreamPlayer = _music_players[_music_active]
	var target := _music_target_db() if enabled else -80.0
	if _music_fade_from != null:
		_music_fade_t = minf(1.0, _music_fade_t + delta / _music_fade_duration)
		var t := _music_fade_t
		var old := _music_fade_from
		if is_instance_valid(old):
			old.volume_db = lerpf(_music_fade_old_db, -80.0, t)
		active.volume_db = lerpf(-60.0, target, t)
		if t >= 1.0:
			if is_instance_valid(old):
				old.stop()
				old.stream = null
			_music_fade_from = null
		return
	active.volume_db = target


func _music_target_db() -> float:
	return MUSIC_DB + linear_to_db(maxf(0.0001, music_volume))


func _on_music_finished(player: AudioStreamPlayer, index: int) -> void:
	if not _music_started or index != _music_active:
		return
	# A track ended naturally: continue with the next one in this context.
	_music_play_next()


func stop_music() -> void:
	for music: AudioStreamPlayer in _music_players:
		music.stop()
		music.stream = null
	_music_started = false
	_music_fade_from = null
	music_track = ""


func stop_all() -> void:
	stop_music()
	for player: AudioStreamPlayer in _players:
		player.stop()
		player.stream = null
	_loops.clear()
	for index in _busy.size():
		_busy[index] = 0


## A player that is not playing, or the one that has been free longest.
func _free_player() -> AudioStreamPlayer:
	for index in _players.size():
		var player: AudioStreamPlayer = _players[index]
		if not player.playing:
			return player
	# Nothing free: take the oldest, which is the least likely to be missed.
	var oldest := 0
	for index in _busy.size():
		if int(_busy[index]) < int(_busy[oldest]):
			oldest = index
	return _players[oldest]
