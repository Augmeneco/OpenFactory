extends Node
## Localisation, mirroring Factorio's ``LocalisedString`` model.
##
## Dictionaries come from ``data/<mod>/locale/<lang>/*.cfg`` and are keyed
## ``"section.key"`` — exactly the shape used inside prototype data, so
## ``{"item-name.iron-plate"}`` resolves without any translation table.

const LOCALE_DIR := "res://assets/data/locale"

var language: String = "en"
var _table: Dictionary = {}
var _fallback: Dictionary = {}

signal language_changed(lang: String)


func _ready() -> void:
	_fallback = _load("en")
	_table = _fallback


func _load(lang: String) -> Dictionary:
	var text := FileAccess.get_file_as_string("%s/%s.json" % [LOCALE_DIR, lang])
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func set_language(lang: String) -> void:
	var table := _load(lang)
	if table.is_empty():
		push_warning("Loc: no locale data for '%s'" % lang)
		return
	language = lang
	_table = table
	language_changed.emit(lang)


func available_languages() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(LOCALE_DIR)
	if dir:
		for f in dir.get_files():
			if f.ends_with(".json"):
				out.append(f.get_basename())
	return out


## Raw lookup of a ``"section.key"`` identifier.
func key(id: String) -> String:
	var value: Variant = _table.get(id)
	if value == null:
		value = _fallback.get(id)
	if value == null:
		return id
	return str(value)


## Resolve any Factorio LocalisedString into display text.
##
## Accepted shapes: a plain string, ``["key"]``, ``["key", arg1, arg2, ...]``
## with ``__1__``-style placeholders, and arbitrarily nested arrays.
func resolve(value: Variant) -> String:
	if value == null:
		return ""
	if value is String:
		return value
	if value is Array:
		if value.is_empty():
			return ""
		var head: Variant = value[0]
		# A LocalisedString whose first element is itself a string key.
		if head is String:
			var text := key(head)
			for i in range(1, value.size()):
				var arg := resolve(value[i])
				text = text.replace("__%d__" % i, arg)
				text = text.replace("__%d__" % (i), arg)
			return text
		# Otherwise it is a nested composition — concatenate the parts.
		var parts := PackedStringArray()
		for part in value:
			parts.append(resolve(part))
		return "".join(parts)
	return str(value)


## Name of a prototype as the player should see it.
func proto_name(proto_type: String, proto_name_value: String) -> String:
	var proto := Prototypes.get_p(proto_type, proto_name_value)
	return proto_display_name(proto, proto_name_value)


func proto_display_name(proto: Dictionary, fallback_name: String) -> String:
	if proto.has("localised_name"):
		var resolved := resolve(proto["localised_name"])
		if not resolved.is_empty():
			return resolved
	var guess := "%s-name.%s" % [_name_section(proto.get("type", "")), fallback_name]
	var value := key(guess)
	if value != guess:
		return value
	return _humanize(fallback_name)


func proto_description(proto: Dictionary) -> String:
	if proto.has("localised_description"):
		return resolve(proto["localised_description"])
	return ""


const ITEM_TYPES := [
	"item", "tool", "module", "ammo", "capsule", "gun", "armor",
	"repair-tool", "item-with-entity-data", "rail-planner", "blueprint",
	"blueprint-book", "deconstruction-item", "upgrade-item", "spidertron-remote",
	"selection-tool", "copy-paste-tool", "mining-tool", "item-with-tags",
	"item-with-label", "item-with-inventory", "space-platform-starter-pack",
]

const SECTION_OVERRIDES := {
	"recipe": "recipe-name",
	"technology": "technology-name",
	"fluid": "fluid-name",
	"tile": "tile-name",
	"virtual-signal": "virtual-signal-name",
	"damage-type": "damage-type-name",
}


## Map a prototype type onto the locale section Factorio uses for its name.
static func _name_section(proto_type: String) -> String:
	if ITEM_TYPES.has(proto_type):
		return "item-name"
	if SECTION_OVERRIDES.has(proto_type):
		return SECTION_OVERRIDES[proto_type]
	return "%s-name" % proto_type


## "fast-transport-belt" -> "Fast transport belt" for the rare prototype with
## no locale entry at all.
static func _humanize(name: String) -> String:
	var spaced := name.replace("-", " ").replace("_", " ")
	return spaced.substr(0, 1).to_upper() + spaced.substr(1)
