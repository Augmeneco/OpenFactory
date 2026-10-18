class_name Energy
extends RefCounted
## Parsing of Factorio's energy strings ("90kW", "4MJ", "1.21GW").
##
## Prototypes write every power value as a short human-readable string, so the
## simulation needs a parser for them.  Values are in joules; per-tick
## consumption multiplies by ``Simulation.TICK_DELTA``.

const UNITS := {
	"": 1.0,
	"W": 1.0,
	"KW": 1.0e3,
	"MW": 1.0e6,
	"GW": 1.0e9,
	"TW": 1.0e12,
	"J": 1.0,
	"KJ": 1.0e3,
	"MJ": 1.0e6,
	"GJ": 1.0e9,
	"TJ": 1.0e12,
}


## Parse a Factorio energy or power string into a plain number (J or W).
static func parse(value: Variant, fallback := 0.0) -> float:
	if value == null:
		return fallback
	if value is float or value is int:
		return float(value)
	var text := str(value).strip_edges()
	if text.is_empty():
		return fallback
	var split := 0
	while split < text.length() and (text[split].is_valid_float() or text[split] == "." \
			or text[split] == "-" or text[split] == "+"):
		split += 1
	var number := text.substr(0, split)
	var suffix := text.substr(split).strip_edges().to_upper()
	if number.is_empty() or not number.is_valid_float():
		return fallback
	return float(number) * float(UNITS.get(suffix, 1.0))


## Fuel value of an item prototype, or 0 when it does not burn.
static func fuel_value(item_name: String) -> float:
	var item := Prototypes.get_p("item", item_name)
	if item.is_empty():
		item = Prototypes.get_p("capsule", item_name)
	return parse(item.get("fuel_value"), 0.0)


static func is_fuel(item_name: String) -> bool:
	return fuel_value(item_name) > 0.0


## Running draw of a machine prototype, in watts.  Most machines say
## ``energy_usage``; a boiler says ``energy_consumption``.
static func usage(proto: Dictionary) -> float:
	var value: Variant = proto.get("energy_usage")
	if value == null:
		value = proto.get("energy_consumption")
	return parse(value, 0.0)


static func drain(proto: Dictionary) -> float:
	var source: Variant = proto.get("energy_source", {})
	if source is Dictionary:
		return parse(source.get("drain"), 0.0)
	return 0.0


static func is_electric(proto: Dictionary) -> bool:
	var source: Variant = proto.get("energy_source", {})
	return source is Dictionary and str(source.get("type", "")) == "electric"


static func is_burner(proto: Dictionary) -> bool:
	var source: Variant = proto.get("energy_source", {})
	return source is Dictionary and str(source.get("type", "")) == "burner"


## Human readable form, for the GUI.
static func format(joules: float) -> String:
	var value := absf(joules)
	if value >= 1.0e12:
		return "%.2f TJ" % (joules / 1.0e12)
	if value >= 1.0e9:
		return "%.2f GJ" % (joules / 1.0e9)
	if value >= 1.0e6:
		return "%.2f MJ" % (joules / 1.0e6)
	if value >= 1.0e3:
		return "%.2f kJ" % (joules / 1.0e3)
	return "%.2f J" % joules
