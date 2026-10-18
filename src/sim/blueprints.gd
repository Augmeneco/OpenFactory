class_name Blueprints
extends RefCounted
## Copying a patch of factory and pasting it somewhere else.
##
## A blueprint is plain data — the size of the area and a list of entities with
## their prototype, position within the blueprint, direction and whatever state
## matters for the machine to be the same machine (a recipe, a chest's
## requests, which half of an underground belt it is).  Pasting puts down
## everything the player can afford and leaves the rest as ghosts, which is
## exactly what Factorio does when you are short of something.

## The item a blueprint is carried as.
const ITEM := "blueprint"


## Everything in a rectangle worth copying.
static func capture(world: GameWorld, rect: Rect2i) -> Dictionary:
	var entities: Array = []
	var origin := rect.position
	for entity: Entity in world.entities.values():
		if entity.is_ghost():
			continue
		if entity.origin.x < rect.position.x or entity.origin.y < rect.position.y:
			continue
		if entity.origin.x + entity.size.x > rect.position.x + rect.size.x:
			continue
		if entity.origin.y + entity.size.y > rect.position.y + rect.size.y:
			continue
		entities.append({
			"type": entity.proto_type,
			"name": entity.name,
			"origin": [entity.origin.x - origin.x, entity.origin.y - origin.y],
			"direction": entity.direction,
			"state": _state_of(entity),
		})
	# Baked in a fixed order so two blueprints of the same patch match.
	entities.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ao: Array = a["origin"]
		var bo: Array = b["origin"]
		if int(ao[1]) != int(bo[1]):
			return int(ao[1]) < int(bo[1])
		return int(ao[0]) < int(bo[0]))
	return {
		"version": 1,
		"size": [rect.size.x, rect.size.y],
		"entities": entities,
	}


## The parts of an entity's state that make it the same machine again.
static func _state_of(entity: Entity) -> Dictionary:
	var out: Dictionary = {}
	for key: String in ["recipe", "io", "requests", "bar", "requests_enabled"]:
		if entity.state.has(key):
			var value: Variant = entity.state[key]
			if value is Dictionary or value is Array or value is String \
					or value is float or value is int or value is bool:
				out[key] = value
	return out


static func size_of(blueprint: Dictionary) -> Vector2i:
	var size: Variant = blueprint.get("size", [1, 1])
	if size is Array and (size as Array).size() >= 2:
		return Vector2i(int(size[0]), int(size[1]))
	return Vector2i.ONE


## Put a blueprint down with its top-left corner at ``origin``.
##
## Returns ``{ built, ghosts, blocked }``: how many machines went up, how many
## are waiting for materials, and how many cells were occupied by something
## else entirely.
static func place(world: GameWorld, blueprint: Dictionary, origin: Vector2i,
		inventory: Inventory = null) -> Dictionary:
	var built: Array = []
	var ghosts: Array = []
	var blocked: Array = []
	for entry: Variant in blueprint.get("entities", []):
		if not (entry is Dictionary):
			continue
		var record: Dictionary = entry
		var local: Variant = record.get("origin", [0, 0])
		if not (local is Array) or (local as Array).size() < 2:
			continue
		var cell := origin + Vector2i(int(local[0]), int(local[1]))
		var proto_type := str(record.get("type", "entity"))
		var name := str(record.get("name", ""))
		var direction := int(record.get("direction", 0))

		# Something real is already there: leave it alone.
		var occupant := world.entity_at(cell)
		if occupant != null and not occupant.is_ghost():
			blocked.append(cell)
			continue

		var costs := costs_of(proto_type, name)
		if inventory != null and not costs.is_empty() \
				and not inventory.has_at_least(costs):
			var ghost := Entity.create(proto_type, name, cell, direction)
			_apply_state(ghost, record)
			if world.place_ghost(ghost):
				ghosts.append(cell)
			continue

		var entity := Entity.create(proto_type, name, cell, direction)
		if not world.can_place_terrain(entity):
			# The ground cannot take the machine (water, or a drill with no
			# ore).  Leave the plan as a ghost so robots can wait for it.
			_apply_state(entity, record)
			if world.place_ghost(entity):
				ghosts.append(cell)
			continue
		if not world.place_entity(entity):
			blocked.append(cell)
			continue
		_apply_state(entity, record)
		if inventory != null:
			for cost: Dictionary in costs:
				inventory.extract(str(cost["name"]), int(cost["amount"]))
		# An underground belt laid next to its pair has to know which it is.
		world.orient_underground(entity)
		built.append(cell)
	return {"built": built, "ghosts": ghosts, "blocked": blocked}


static func _apply_state(entity: Entity, record: Dictionary) -> void:
	var saved: Variant = record.get("state", {})
	if not (saved is Dictionary):
		return
	for key: String in saved:
		entity.state[key] = saved[key]


## What one of a prototype costs to build, as a list of ``{ name, amount }``.
##
## Every ingredient of the recipe counts — a burner mining drill needs gear
## wheels, plates *and* a furnace — so a blueprint is only built where the
## inventory can cover the whole bill.
static func costs_of(proto_type: String, name: String) -> Array:
	var out: Array = []
	for recipe_name: String in Prototypes.all("recipe"):
		var recipe := Prototypes.get_p("recipe", recipe_name)
		var products := Prototypes.recipe_products(recipe)
		if products.size() != 1 or str(products[0]["name"]) != name:
			continue
		for ingredient: Dictionary in Prototypes.recipe_ingredients(recipe):
			if str(ingredient.get("type", "item")) == "fluid":
				continue
			out.append({"name": str(ingredient["name"]),
				"amount": int(ingredient["amount"])})
		return out
	return out


## The item a blueprint is stored as, with the data in its tags.
static func to_item(blueprint: Dictionary) -> Dictionary:
	return {"name": ITEM, "count": 1, "blueprint": blueprint}


static func from_item(item: Dictionary) -> Dictionary:
	var data: Variant = item.get("blueprint", {})
	return data if data is Dictionary else {}
