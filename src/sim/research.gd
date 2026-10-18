class_name Research
extends RefCounted
## The technology tree and the research that unlocks it.
##
## Factorio 2.0 starts with exactly two root technologies — ``steam-power`` and
## ``electronics`` — and both are *trigger* technologies: they are not studied
## in a lab, they complete when the player has produced enough of something
## (50 iron plates, 10 copper plates).  Everything else hangs off those two
## through ``prerequisites`` and is researched in labs by feeding them science
## packs.
##
## The class tracks what has been researched, what is available, the current
## project and its progress, and answers the question the crafting menu asks:
## "is this recipe unlocked yet?"

var technologies: Dictionary = {}
## Names of finished technologies.
var researched: Dictionary = {}
## The technology currently being studied ("" when idle).
var current: String = ""
## Completed units of the current technology.
var units_done: int = 0
## Seconds of lab work accumulated towards the next unit.
var work: float = 0.0

## Production counters that trigger technologies watch.
var produced: Dictionary = {}      ## item name -> count
var built: Dictionary = {}         ## entity prototype name -> count
var mined_entities: Dictionary = {} ## entity prototype name -> count

var _recipes: Dictionary = {}      ## recipe name -> true, rebuilt on unlock
var _available_cache: Array = []
var _cache_valid := false

signal technology_researched(name: String)
signal research_changed
signal availability_changed


func _init() -> void:
	technologies = Prototypes.all("technology")
	rebuild_effects()


# --------------------------------------------------------------------------
# graph
# --------------------------------------------------------------------------

func has(name: String) -> bool:
	return technologies.has(name)


func proto(name: String) -> Dictionary:
	var entry: Variant = technologies.get(name)
	return entry if entry is Dictionary else {}


func is_researched(name: String) -> bool:
	return researched.has(name)


## The technology's ``unit`` block, or an empty dictionary for trigger techs.
func unit_of(name: String) -> Dictionary:
	var entry := proto(name)
	var unit: Variant = entry.get("unit")
	return unit if unit is Dictionary else {}


func is_trigger(name: String) -> bool:
	return proto(name).has("research_trigger")


func prerequisites_met(name: String) -> bool:
	for prerequisite: Variant in proto(name).get("prerequisites", []):
		if not is_researched(str(prerequisite)):
			return false
	return true


## Whether the technology may be started right now.
func is_available(name: String) -> bool:
	if is_researched(name) or name == current:
		return false
	# Trigger technologies complete on their own; they are never "started".
	if is_trigger(name):
		return false
	return prerequisites_met(name)


func available_technologies() -> Array:
	if _cache_valid:
		return _available_cache
	var out: Array = []
	for name: String in technologies:
		if is_available(name):
			out.append(name)
	out.sort_custom(func(a: String, b: String) -> bool:
		var ua := unit_of(a)
		var ub := unit_of(b)
		var ca := int(ua.get("count", 0)) * int(ua.get("time", 0))
		var cb := int(ub.get("count", 0)) * int(ub.get("time", 0))
		if ca != cb:
			return ca < cb
		return a < b)
	_available_cache = out
	_cache_valid = true
	return out


## Every prerequisite branch that leads to ``name``, for the tree view.
func needs_of(name: String) -> Array:
	return proto(name).get("prerequisites", [])


# --------------------------------------------------------------------------
# start / progress
# --------------------------------------------------------------------------

func start(name: String) -> bool:
	if not is_available(name):
		return false
	current = name
	units_done = 0
	work = 0.0
	research_changed.emit()
	return true


func cancel() -> void:
	if current.is_empty():
		return
	current = ""
	units_done = 0
	work = 0.0
	research_changed.emit()


## Science packs the current project needs, as ``[[name, amount], ...]``.
func current_ingredients() -> Array:
	if current.is_empty():
		return []
	return unit_of(current).get("ingredients", [])


## Seconds of lab work one unit costs.
func unit_time() -> float:
	return maxf(1.0, float(unit_of(current).get("time", 1.0)))


func total_units() -> int:
	return maxi(1, int(unit_of(current).get("count", 1)))


## 0..1 progress of the whole technology.
func progress() -> float:
	if current.is_empty():
		return 0.0
	var total := float(total_units())
	return clampf((float(units_done) + clampf(work / unit_time(), 0.0, 1.0)) / total,
		0.0, 1.0)


## Add lab work.  ``consume`` is called once per finished unit and must return
## true when the science packs for that unit were actually taken.
func add_work(seconds: float, consume: Callable) -> void:
	if current.is_empty() or seconds <= 0.0:
		return
	work += seconds
	var completed := 0
	while work >= unit_time() and units_done < total_units():
		if not bool(consume.call()):
			break
		work -= unit_time()
		units_done += 1
		completed += 1
	if completed > 0:
		research_changed.emit()
	if units_done >= total_units():
		_finish()


## Creative worlds start with every technology already finished.
func unlock_all() -> void:
	researched.clear()
	for name: String in technologies:
		researched[name] = true
	current = ""
	units_done = 0
	work = 0.0
	rebuild_effects()
	research_changed.emit()
	availability_changed.emit()


func _finish() -> void:
	var finished := current
	current = ""
	units_done = 0
	work = 0.0
	researched[finished] = true
	rebuild_effects()
	technology_researched.emit(finished)
	research_changed.emit()
	availability_changed.emit()


# --------------------------------------------------------------------------
# triggers
# --------------------------------------------------------------------------

## Record that ``count`` of an item was produced (hand crafting, a machine, or
## mining).  Trigger technologies watching that item may complete.
func on_item_produced(item_name: String, count: int) -> void:
	if count <= 0:
		return
	produced[item_name] = int(produced.get(item_name, 0)) + count
	_check_triggers()


func on_entity_built(entity_name: String) -> void:
	built[entity_name] = int(built.get(entity_name, 0)) + 1
	_check_triggers()


func on_entity_mined(entity_name: String) -> void:
	mined_entities[entity_name] = int(mined_entities.get(entity_name, 0)) + 1
	_check_triggers()


func trigger_satisfied(name: String) -> bool:
	var trigger: Variant = proto(name).get("research_trigger")
	if not (trigger is Dictionary):
		return false
	var count := maxi(1, int(trigger.get("count", 1)))
	match str(trigger.get("type", "")):
		"craft-item":
			return int(produced.get(str(trigger.get("item", "")), 0)) >= count
		"build-entity":
			return int(built.get(str(trigger.get("entity", "")), 0)) >= count
		"mine-entity":
			return int(mined_entities.get(str(trigger.get("entity", "")), 0)) >= count
	return false


## How far along a trigger technology is, for the interface.
func trigger_progress(name: String) -> float:
	var trigger: Variant = proto(name).get("research_trigger")
	if not (trigger is Dictionary):
		return 0.0
	var count := maxi(1, int(trigger.get("count", 1)))
	match str(trigger.get("type", "")):
		"craft-item":
			return clampf(float(int(produced.get(str(trigger.get("item", "")), 0)))
				/ float(count), 0.0, 1.0)
		"build-entity":
			return clampf(float(int(built.get(str(trigger.get("entity", "")), 0)))
				/ float(count), 0.0, 1.0)
		"mine-entity":
			return clampf(float(int(mined_entities.get(str(trigger.get("entity", "")), 0)))
				/ float(count), 0.0, 1.0)
	return 0.0


func trigger_description(name: String) -> String:
	var trigger: Variant = proto(name).get("research_trigger")
	if not (trigger is Dictionary):
		return ""
	var count := maxi(1, int(trigger.get("count", 1)))
	var target := "%s (%dx)" % [Loc.proto_name("item", str(trigger.get("item", ""))), count]
	match str(trigger.get("type", "")):
		"craft-item":
			return "Produce %s" % target
		"build-entity":
			return "Build %s" % Loc.proto_name("entity", str(trigger.get("entity", "")))
		"mine-entity":
			return "Mine %s" % Loc.proto_name("entity", str(trigger.get("entity", "")))
		_:
			return str(trigger.get("type", ""))


func _check_triggers() -> void:
	var changed := false
	for name: String in technologies:
		if is_researched(name) or not is_trigger(name):
			continue
		if not prerequisites_met(name):
			continue
		if not trigger_satisfied(name):
			continue
		researched[name] = true
		changed = true
		technology_researched.emit(name)
	if changed:
		rebuild_effects()
		_cache_valid = false
		research_changed.emit()
		availability_changed.emit()


# --------------------------------------------------------------------------
# unlocked recipes
# --------------------------------------------------------------------------

## Recipes that need no research at all plus everything unlocked so far.
## The bonuses the researched technologies hand out.
var modifiers: Modifiers


## Rebuild both the recipe unlocks and the numeric bonuses.
##
## Every path that changes ``researched`` goes through here — a finished
## technology, a cancelled one, and loading a save — so the two never drift.
func rebuild_effects() -> void:
	rebuild_unlocks()
	if modifiers == null:
		modifiers = Modifiers.new()
	modifiers.rebuild(self)


func rebuild_unlocks() -> void:
	_recipes.clear()
	for recipe_name: String in Prototypes.names("recipe"):
		var recipe := Prototypes.get_p("recipe", recipe_name)
		# Factorio's ``enabled`` defaults to true; only recipes that say
		# ``enabled = false`` are locked behind research.
		var flag: Variant = recipe.get("enabled")
		if flag == null or bool(flag):
			_recipes[recipe_name] = true
	for name: String in researched:
		for effect: Variant in proto(name).get("effects", []):
			if effect is Dictionary and str(effect.get("type", "")) == "unlock-recipe":
				_recipes[str(effect.get("recipe", ""))] = true
	_cache_valid = false


func is_recipe_unlocked(recipe_name: String) -> bool:
	return _recipes.has(recipe_name)


func unlocked_recipe_count() -> int:
	return _recipes.size()


## Which technology unlocks this recipe, or "" when it needs none.
func unlocking_technology(recipe_name: String) -> String:
	for name: String in technologies:
		for effect: Variant in proto(name).get("effects", []):
			if effect is Dictionary and str(effect.get("type", "")) == "unlock-recipe" \
					and str(effect.get("recipe", "")) == recipe_name:
				return name
	return ""


func summary() -> Dictionary:
	return {
		"researched": researched.size(),
		"total": technologies.size(),
		"recipes_unlocked": unlocked_recipe_count(),
		"current": current,
		"progress": progress(),
		"available": available_technologies().size(),
	}
