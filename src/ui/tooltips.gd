class_name Tooltips
extends RefCounted
## Factorio-style tooltip text.
##
## The look is already Factorio's — `FactorioStyle` puts the real
## `tooltip_frame`, `tooltip_title_label` and `tooltip_label` styles into the
## Godot theme — so what is left is the content: a bold name, the item's own
## description from the locale, and the numbers a player wants to see before
## placing something down.

## Factorio writes the name on the first line and leaves the rest to the
## description and the stats, which is what these build.


## The structured card the tooltip layer draws.
##
## ``{ title, description, rows: [{ icon, text, tint }], footer }`` — the same
## shape for items, recipes, machines and technologies, so one widget can draw
## them all.  The plain-text helpers below still exist for anything that has to
## fall back to Godot's own tooltip.


static func item_card(item_name: String) -> Dictionary:
	var proto := Prototypes.item_proto(item_name)
	if proto.is_empty():
		return {"title": item_name, "rows": []}
	var rows: Array = []
	rows.append({"text": "Stack size: %d" % Prototypes.stack_size(item_name)})
	var fuel := Energy.fuel_value(item_name)
	if fuel > 0.0:
		rows.append({"text": "Fuel value: %s" % Energy.format(fuel)})

	var place_result: Variant = proto.get("place_result")
	var icon: Texture2D = null
	if place_result != null:
		var placed := Prototypes.get_p("item", str(place_result))
		if placed.is_empty():
			placed = Prototypes.item_proto(str(place_result))
		rows.append({"text": "Places: %s" % Loc.proto_display_name(placed,
			str(place_result))})
		icon = FactorioAssets.prototype_icon(placed, 64)
	elif not Prototypes.get_p("ammo", item_name).is_empty():
		var damage := Simulation._attack_damage(
			Prototypes.get_p("ammo", item_name).get("ammo_type", {}))
		if not damage.is_empty():
			rows.append({"text": "%s damage: %s" % [
				str(damage.get("type", "physical")).capitalize(),
				_number(float(damage.get("amount", 0.0)))],
				"icon": FactorioAssets.recipe_icon({}, 64) if false else null})
	elif not Prototypes.get_p("gun", item_name).is_empty():
		var attack: Variant = Prototypes.get_p("gun", item_name).get(
			"attack_parameters", {})
		if attack is Dictionary:
			rows.append({"text": "Range: %s tiles" % _number(
				float(attack.get("range", 0.0)))})
			rows.append({"text": "Cooldown: %d ticks" % int(
				attack.get("cooldown", 0))})
	return {
		"title": Loc.proto_display_name(proto, item_name),
		"description": Loc.proto_description(proto),
		"rows": rows,
		"icon": icon,
	}


static func recipe_card(recipe_name: String) -> Dictionary:
	var recipe := Prototypes.get_p("recipe", recipe_name)
	if recipe.is_empty():
		return {"title": recipe_name, "rows": []}
	var rows: Array = []
	rows.append({"text": "Ingredients", "heading": true})
	for ingredient: Dictionary in Prototypes.recipe_ingredients(recipe):
		rows.append({
			"icon": _entry_icon(ingredient),
			"text": "%s  x%s" % [_label(ingredient),
				_number(float(ingredient["amount"]))],
		})
	rows.append({"text": "Products", "heading": true})
	for product: Dictionary in Prototypes.recipe_products(recipe):
		var chance := float(product.get("probability", 1.0))
		var suffix := "" if chance >= 1.0 else "  (%.0f%%)" % (chance * 100.0)
		rows.append({
			"icon": _entry_icon(product),
			"text": "%s  x%s%s" % [_label(product),
				_number(float(product["amount"])), suffix],
		})
	return {
		"title": Loc.proto_name("recipe", recipe_name),
		"description": "",
		"rows": rows,
		"footer": "%.1f s   %s" % [Prototypes.recipe_energy(recipe),
			str(recipe.get("category", "crafting"))],
	}


static func entity_card(entity: Entity) -> Dictionary:
	var proto := entity.prototype()
	if proto.is_empty():
		return {"title": entity.name, "rows": []}
	var rows: Array = []
	var max_health := float(proto.get("max_health", 0.0))
	if max_health > 0.0:
		rows.append({"text": "Health: %.0f / %.0f" % [
			float(entity.state.get("health", max_health)), max_health]})
	var recipe_name := str(entity.state.get("recipe", ""))
	if not recipe_name.is_empty():
		rows.append({"text": "Recipe: %s" % Loc.proto_name("recipe", recipe_name)})
	var mode := LogisticNetwork.mode_of(entity)
	if not mode.is_empty():
		rows.append({"text": "Logistic: %s" % mode.replace("-", " ").capitalize()})
	for spec: Dictionary in FluidSystem.box_specs(entity):
		var filter := str(spec.get("filter", ""))
		rows.append({"text": "%s: %s" % [str(spec["name"]).capitalize(),
			Loc.proto_name("fluid", filter) if not filter.is_empty()
				else "any fluid"]})
	return {
		"title": Loc.proto_display_name(proto, entity.name),
		"description": Loc.proto_description(proto),
		"rows": rows,
		"icon": FactorioAssets.prototype_icon(proto, 64),
	}


static func technology_card(research: Research, name: String) -> Dictionary:
	var proto := Prototypes.get_p("technology", name)
	if proto.is_empty():
		return {"title": name, "rows": []}
	var rows: Array = []
	if research.is_researched(name):
		rows.append({"text": "Researched"})
	elif research.is_trigger(name):
		rows.append({"text": "Unlocked by doing: %s"
			% research.trigger_description(name)})
	var unit := research.unit_of(name)
	if not unit.is_empty():
		rows.append({"text": "Cost", "heading": true})
		rows.append({"text": "%d units x %.0f s" % [int(unit.get("count", 0)),
			float(unit.get("time", 0.0))]})
		for ingredient: Variant in unit.get("ingredients", []):
			if not (ingredient is Array) or (ingredient as Array).size() < 2:
				continue
			rows.append({
				"icon": FactorioAssets.prototype_icon(
					Prototypes.item_proto(str(ingredient[0])), 64),
				"text": "%s  x%d" % [Loc.proto_name("item", str(ingredient[0])),
					int(ingredient[1])],
			})
	var unlocked: Array = []
	for effect: Variant in proto.get("effects", []):
		if effect is Dictionary and str(effect.get("type", "")) == "unlock-recipe":
			unlocked.append(str(effect.get("recipe", "")))
	if not unlocked.is_empty():
		rows.append({"text": "Unlocks", "heading": true})
		for recipe_name: String in unlocked:
			rows.append({
				"icon": FactorioAssets.recipe_icon(
					Prototypes.get_p("recipe", recipe_name), 64),
				"text": Loc.proto_name("recipe", recipe_name),
			})
	return {
		"title": Loc.proto_name("technology", name),
		"description": Loc.proto_description(proto),
		"rows": rows,
	}


# --------------------------------------------------------------------------
# plain-text fallback
# --------------------------------------------------------------------------

## The same content as text, for Godot's own tooltip where the custom layer is
## not running — a bare test scene, for instance.
static func to_text(card: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append(str(card.get("title", "")))
	var description := str(card.get("description", ""))
	if not description.is_empty():
		lines.append(description)
	for row: Variant in card.get("rows", []):
		if not (row is Dictionary):
			continue
		var text := str(row.get("text", ""))
		lines.append(text if bool(row.get("heading", false)) else "  " + text)
	var footer := str(card.get("footer", ""))
	if not footer.is_empty():
		lines.append(footer)
	return "\n".join(lines)


static func for_item(item_name: String) -> String:
	return to_text(item_card(item_name))


static func for_recipe(recipe_name: String) -> String:
	return to_text(recipe_card(recipe_name))


static func for_entity(entity: Entity) -> String:
	return to_text(entity_card(entity))


static func _entry_icon(entry: Dictionary) -> Texture2D:
	if str(entry.get("type", "item")) == "fluid":
		return FactorioAssets.prototype_icon(
			Prototypes.get_p("fluid", str(entry["name"])), 64)
	return FactorioAssets.prototype_icon(
		Prototypes.item_proto(str(entry["name"])), 64)


static func _label(entry: Dictionary) -> String:
	var kind := "fluid" if str(entry.get("type", "item")) == "fluid" else "item"
	return Loc.proto_name(kind, str(entry["name"]))


static func _number(value: float) -> String:
	return str(int(value)) if is_equal_approx(value, roundf(value)) \
		else "%.2f" % value
