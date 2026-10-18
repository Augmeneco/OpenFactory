class_name ResearchTree
extends Control
## Factorio's technology tree: cards laid out in tiers with connector lines.
##
## A technology sits one column right of its deepest prerequisite, and inside a
## column it is ordered by where its prerequisites ended up — the usual layered
## graph arrangement, which is what keeps the lines from crossing into a
## spaghetti.  The lines themselves are drawn here; the cards are child
## buttons, so clicking one is ordinary Control input.

const CARD := 64.0
const COLUMN_GAP := 34.0
const ROW_GAP := 12.0
## How many times the ordering is relaxed.  Three passes is plenty for a tree
## this shape and keeps the rebuild instant.
const ORDER_PASSES := 4

signal technology_selected(name: String)
signal technology_chosen(name: String)

var research: Research

## name -> { tier, row, position }
var layout: Dictionary = {}
var tiers: Array = []          ## tier index -> Array of names

var _cards: Dictionary = {}    ## name -> Button
var _only_main := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	if research != null:
		rebuild()


func set_research(research_: Research) -> void:
	research = research_
	rebuild()


## Show only technologies with no optional prerequisites.
func set_only_main(value: bool) -> void:
	_only_main = value
	rebuild()


## Which technologies the tree shows.
##
## With the filter on, only the ones that unlock something are kept — the
## technologies that move production forward.  Factorio's own filter hides its
## optional branches; the label here says what this one actually does.
func _visible_technologies() -> Array:
	var names: Array = []
	for name: String in Prototypes.all("technology"):
		if _only_main and not _unlocks_anything(name):
			continue
		names.append(name)
	return names


static func _unlocks_anything(name: String) -> bool:
	for effect: Variant in Prototypes.get_p("technology", name).get("effects", []):
		if not (effect is Dictionary):
			continue
		var kind := str(effect.get("type", ""))
		if kind == "unlock-recipe" or kind == "unlock-quality" \
				or kind == "unlock-space-location":
			return true
	return false


# --------------------------------------------------------------------------
# layout
# --------------------------------------------------------------------------

func rebuild() -> void:
	for card: Node in _cards.values():
		card.queue_free()
	_cards.clear()
	layout.clear()
	tiers.clear()
	if research == null:
		return

	var names := _visible_technologies()
	var in_tree: Dictionary = {}
	for name: String in names:
		in_tree[name] = true

	# Longest path from the roots decides the column.
	var tier: Dictionary = {}
	for name: String in names:
		tier[name] = 0
	for _pass in names.size():
		var moved := false
		for name: String in names:
			for prerequisite: Variant in Prototypes.get_p("technology",
					name).get("prerequisites", []):
				if not in_tree.has(prerequisite):
					continue
				if int(tier[name]) < int(tier[prerequisite]) + 1:
					tier[name] = int(tier[prerequisite]) + 1
					moved = true
		if not moved:
			break

	var deepest := 0
	for name: String in names:
		deepest = maxi(deepest, int(tier[name]))
	for index in deepest + 1:
		tiers.append([])
	for name: String in names:
		(tiers[int(tier[name])] as Array).append(name)

	# Order each column by the average position of what feeds it, then relax.
	for column: Array in tiers:
		column.sort()
	var row: Dictionary = {}
	for index in tiers.size():
		for position in (tiers[index] as Array).size():
			row[(tiers[index] as Array)[position]] = position
	for _pass in ORDER_PASSES:
		for index in range(1, tiers.size()):
			var column: Array = tiers[index]
			var keyed: Array = []
			for name: String in column:
				var total := 0.0
				var count := 0
				for prerequisite: Variant in Prototypes.get_p("technology",
						name).get("prerequisites", []):
					if row.has(prerequisite):
						total += float(row[prerequisite])
						count += 1
				keyed.append({"name": name,
					"key": total / float(count) if count > 0 else float(row.get(name, 0))})
			keyed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				if is_equal_approx(float(a["key"]), float(b["key"])):
					return str(a["name"]) < str(b["name"])
				return float(a["key"]) < float(b["key"]))
			column.clear()
			for position in keyed.size():
				var name := str(keyed[position]["name"])
				column.append(name)
				row[name] = position

	# Place the cards.
	var widest := 0
	for index in tiers.size():
		widest = maxi(widest, (tiers[index] as Array).size())
	custom_minimum_size = Vector2(
		float(tiers.size()) * (CARD + COLUMN_GAP),
		float(widest) * (CARD + ROW_GAP))
	size = custom_minimum_size

	for index in tiers.size():
		var column: Array = tiers[index]
		# Columns are top-aligned, so the roots are the first thing you see
		# when the view scrolls to the start.
		var top := 0.0
		for position in column.size():
			var name := str(column[position])
			layout[name] = {
				"tier": index, "row": position,
				"position": Vector2(float(index) * (CARD + COLUMN_GAP),
					top + float(position) * (CARD + ROW_GAP)),
			}
			_add_card(name)

	queue_redraw()


func card_rect(name: String) -> Rect2:
	var entry: Variant = layout.get(name)
	if entry == null:
		return Rect2()
	return Rect2(Vector2((entry as Dictionary)["position"]), Vector2(CARD, CARD))


## The style a technology's card wears, which is the whole state display.
func style_for(name: String) -> String:
	if research.is_researched(name):
		return "researched_technology_slot"
	if research.is_available(name):
		return "available_technology_slot"
	if research.prerequisites_met(name) and research.is_trigger(name):
		return "conditionally_available_technology_slot"
	return "unavailable_technology_slot"


func _add_card(name: String) -> void:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.flat = false
	button.clip_contents = true
	button.position = (layout[name] as Dictionary)["position"]
	button.size = Vector2(CARD, CARD)
	button.custom_minimum_size = Vector2(CARD, CARD)
	if research != null:
		TooltipLayer.attach(button, Tooltips.technology_card(research, name))
	button.set_meta("technology", name)
	button.set_meta("factorio_style", style_for(name))

	for state: String in ["default", "hovered", "clicked"]:
		var box := FactorioStyle.stylebox(style_for(name),
			String({"default": "default", "hovered": "hovered", "clicked": "clicked"}[state]))
		if box == null:
			box = FactorioStyle.stylebox("button", state)
		if box != null:
			button.add_theme_stylebox_override(
				String({"default": "normal", "hovered": "hover", "clicked": "pressed"}[state]), box)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_stylebox_override("disabled", StyleBoxEmpty.new())

	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture = FactorioAssets.icon_for("technology", name, 64)
	icon.set_meta("factorio_icon", "technology-%s" % name)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 5
	icon.offset_top = 5
	icon.offset_right = -5
	icon.offset_bottom = -5
	button.add_child(icon)

	button.pressed.connect(func() -> void: technology_chosen.emit(name))
	button.mouse_entered.connect(func() -> void: technology_selected.emit(name))
	add_child(button)
	_cards[name] = button


func refresh() -> void:
	for name: String in _cards:
		var button: Button = _cards[name]
		var wanted := style_for(name)
		if str(button.get_meta("factorio_style", "")) == wanted:
			continue
		button.set_meta("factorio_style", wanted)
		for state: String in ["default", "hovered", "clicked"]:
			var box := FactorioStyle.stylebox(wanted, state)
			if box == null:
				box = FactorioStyle.stylebox("button", state)
			if box != null:
				button.add_theme_stylebox_override(
					String({"default": "normal", "hovered": "hover", "clicked": "pressed"}[state]), box)
		if research != null:
			TooltipLayer.attach(button, Tooltips.technology_card(research, name))


func _tooltip(name: String) -> String:
	var lines := PackedStringArray()
	lines.append(Loc.proto_name("technology", name))
	if research.is_researched(name):
		lines.append("Researched")
	elif research.is_trigger(name):
		lines.append("Unlocked by doing: %s" % research.trigger_description(name))
	else:
		var unit := research.unit_of(name)
		if not unit.is_empty():
			lines.append("%d x %.0f s" % [int(unit.get("count", 0)),
				float(unit.get("time", 0.0))])
	for effect: Variant in Prototypes.get_p("technology", name).get("effects", []):
		if effect is Dictionary and str(effect.get("type", "")) == "unlock-recipe":
			lines.append("  %s" % Loc.proto_name("recipe",
				str(effect.get("recipe", ""))))
	return "\n".join(lines)


# --------------------------------------------------------------------------
# the lines
# --------------------------------------------------------------------------

## The connector geometry, in this control's own coordinates.
##
## ``_draw`` cannot be photographed, and the headless UI previewer has no way to
## see it, so the same segments are handed out as data for the dump.
func overlay_lines() -> Array:
	var out: Array = []
	for segment: Dictionary in _segments():
		out.append(segment)
	return out


## Every prerequisite as an elbow connector, brightest where both ends are
## already researched.
func _segments() -> Array:
	var out: Array = []
	if research == null:
		return out
	for name: String in layout:
		var target := card_rect(name)
		if target.size.x <= 0.0:
			continue
		for prerequisite: Variant in Prototypes.get_p("technology", name).get(
				"prerequisites", []):
			if not layout.has(prerequisite):
				continue
			var source := card_rect(str(prerequisite))
			var from := Vector2(source.position.x + source.size.x,
				source.position.y + source.size.y * 0.5)
			var to := Vector2(target.position.x, target.position.y + target.size.y * 0.5)
			var both := research.is_researched(name) \
				and research.is_researched(str(prerequisite))
			var colour := Color(0.85, 0.93, 1.0, 1.0) if both \
				else Color(0.62, 0.68, 0.76, 0.95)
			# Out of the source, along to the middle of the gap, across, in.
			var middle := (from.x + to.x) * 0.5
			out.append({
				"points": [[from.x, from.y], [middle, from.y],
					[middle, to.y], [to.x, to.y]],
				"color": [colour.r, colour.g, colour.b, colour.a],
				"width": 2.0,
			})
	return out


func _draw() -> void:
	for segment: Dictionary in _segments():
		var points := PackedVector2Array()
		for point: Array in segment["points"]:
			points.append(Vector2(float(point[0]), float(point[1])))
		var colour: Array = segment["color"]
		draw_polyline(points, Color(colour[0], colour[1], colour[2], colour[3]),
			float(segment["width"]), true)
