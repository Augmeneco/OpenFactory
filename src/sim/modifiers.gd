class_name Modifiers
extends RefCounted
## The bonuses researched technologies hand out.
##
## Factorio's technologies carry two kinds of effect: the ``unlock-recipe``
## ones, which make something craftable, and the rest, which quietly change a
## number — a bullet does 10 % more, a lab works 20 % faster, a robot carries
## one more stack.  Those are collected here from the same prototype data and
## applied wherever the number is used, so researching physical projectile
## damage really does make the turret hit harder.

## ``category -> multiplier`` for ammunition damage and for how fast a gun
## with that ammunition fires.
var ammo_damage: Dictionary = {}
var gun_speed: Dictionary = {}
## ``turret name -> multiplier``.
var turret_attack: Dictionary = {}

var laboratory_speed := 0.0
var robot_speed := 0.0
var robot_storage := 0
## ``bulk-inserter-capacity-bonus`` raises the number of items an ordinary
## inserter may hold.  ``inserter-stack-size-bonus`` is a separate bonus for
## bulk/stack inserters and must not be copied into every arm's hand size.
var inserter_capacity := 0
var inserter_stack_size := 0
var mining_productivity := 0.0
var character_mining_speed := 0.0
var character_inventory_slots := 0
var character_health := 0.0

## Every effect type seen, so an unimplemented one is visible rather than
## silently dropped.
var seen_effects: Dictionary = {}
var applied_effects: Dictionary = {}


func rebuild(research: Research) -> void:
	_reset()
	if research == null:
		return
	for name: String in research.researched:
		var proto := Prototypes.get_p("technology", name)
		for effect: Variant in proto.get("effects", []):
			if not (effect is Dictionary):
				continue
			_apply(effect)


func _reset() -> void:
	ammo_damage.clear()
	gun_speed.clear()
	turret_attack.clear()
	laboratory_speed = 0.0
	robot_speed = 0.0
	robot_storage = 0
	inserter_capacity = 0
	inserter_stack_size = 0
	mining_productivity = 0.0
	character_mining_speed = 0.0
	character_inventory_slots = 0
	character_health = 0.0
	applied_effects.clear()


func _apply(effect: Dictionary) -> void:
	var kind := str(effect.get("type", ""))
	seen_effects[kind] = int(seen_effects.get(kind, 0)) + 1
	var modifier := float(effect.get("modifier", 0.0))

	match kind:
		"unlock-recipe", "unlock-space-location", "unlock-quality", \
		"unlock-space-platforms", "change-recipe-productivity", \
		"create-ghost-on-entity-death", "cliff-deconstruction-enabled", \
		"character-logistic-requests", "character-logistic-trash-slots", \
		"vehicle-logistics", "mining-with-fluid", "unlock-circuit-network", \
		"rail-planner-allow-elevated-rails", "rail-support-on-deep-oil-ocean":
			# Recipes are handled by the research tree itself; the rest gate
			# features this build does not have yet.
			return
		"ammo-damage":
			_bump(ammo_damage, str(effect.get("ammo_category", "")), modifier)
		"gun-speed":
			# A speed bonus shortens the cooldown rather than lengthening it.
			_bump(gun_speed, str(effect.get("ammo_category", "")), modifier)
		"turret-attack":
			_bump(turret_attack, str(effect.get("turret_id", "")), modifier)
		"laboratory-speed":
			laboratory_speed += modifier
		"worker-robot-speed":
			robot_speed += modifier
		"worker-robot-storage":
			robot_storage += int(modifier)
		"inserter-stack-size-bonus":
			inserter_stack_size += int(modifier)
		"bulk-inserter-capacity-bonus":
			inserter_capacity += int(modifier)
		"mining-drill-productivity-bonus":
			mining_productivity += modifier
		"character-mining-speed":
			character_mining_speed += modifier
		"character-inventory-slots-bonus":
			character_inventory_slots += int(modifier)
		"character-health-bonus":
			character_health += modifier
		_:
			# Recorded above but not applied; ``summary`` names them.
			return
	applied_effects[kind] = int(applied_effects.get(kind, 0)) + 1


static func _bump(table: Dictionary, key: String, amount: float) -> void:
	if key.is_empty():
		return
	table[key] = float(table.get(key, 0.0)) + amount


# --------------------------------------------------------------------------
# lookups
# --------------------------------------------------------------------------

## Damage multiplier for a round of this ammunition category.
func ammo_damage_for(category: String) -> float:
	return 1.0 + float(ammo_damage.get(category, 0.0))


## How much faster a gun with this ammunition fires, as a multiplier on rate.
func gun_speed_for(category: String) -> float:
	return 1.0 + float(gun_speed.get(category, 0.0))


## Damage multiplier for a turret.
func turret_damage_for(turret_name: String) -> float:
	return 1.0 + float(turret_attack.get(turret_name, 0.0))


func research_speed_multiplier() -> float:
	return 1.0 + laboratory_speed


func robot_speed_multiplier() -> float:
	return 1.0 + robot_speed


## How many item units a logistic robot carries per trip.
##
## ``max_payload_size`` counts stacks and the research adds one stack each
## time, so the two are added and then multiplied by the item's stack size.
func robot_payload(item_name: String) -> int:
	var base := maxi(1, int(LogisticNetwork.robot_prototype().get(
		"max_payload_size", 1)))
	return (base + robot_storage) * Prototypes.stack_size(item_name)


func inserter_hand_size() -> int:
	return 1 + inserter_capacity


func mining_productivity_multiplier() -> float:
	return 1.0 + mining_productivity


func character_mining_speed_multiplier() -> float:
	return 1.0 + character_mining_speed


func character_health_bonus() -> float:
	return character_health


func inventory_slots_bonus() -> int:
	return character_inventory_slots


## What is applied and what is not, for the report and the tests.
func summary() -> Dictionary:
	var ignored: Array = []
	for kind: String in seen_effects:
		if kind != "unlock-recipe" and not applied_effects.has(kind):
			ignored.append(kind)
	ignored.sort()
	return {
		"applied": applied_effects.duplicate(),
		"ignored": ignored,
		"ammo_damage": ammo_damage.duplicate(),
		"gun_speed": gun_speed.duplicate(),
		"turret_attack": turret_attack.duplicate(),
		"laboratory_speed": laboratory_speed,
		"robot_speed": robot_speed,
		"robot_storage": robot_storage,
		"inserter_capacity": inserter_capacity,
		"inserter_stack_size": inserter_stack_size,
		"mining_productivity": mining_productivity,
		"character_health": character_health,
		"character_mining_speed": character_mining_speed,
		"inventory_slots": character_inventory_slots,
	}
