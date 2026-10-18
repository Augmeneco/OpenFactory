class_name InventoryLayout
extends RefCounted
## Which inventories each entity type has, and how big they are.
##
## Factorio describes these with per-type prototype fields
## (``source_inventory_size``, ``result_inventory_size``, ``inventory_size``,
## ``module_slots`` ...).  This collects them in one place so the simulation
## can create inventories lazily and the GUI can label them.

const INPUT := "input"
const OUTPUT := "output"
const FUEL := "fuel"
const MODULES := "modules"
const STORAGE := "storage"
const TRASH := "trash"


## ``{ inventory_name: slot_count }`` for an entity.
##
## Whatever the per-type table says, any prototype whose energy source is a
## burner also gets a fuel inventory sized by ``fuel_inventory_size`` — that is
## how a burner mining drill or a burner inserter is fed.
static func for_entity(entity: Entity) -> Dictionary:
	var proto := entity.prototype()
	if proto.is_empty():
		return {}
	var layout := _layout_for(proto, entity.proto_type)
	var fuel := fuel_slots(proto)
	if fuel > 0 and not layout.has(FUEL):
		layout[FUEL] = fuel
	return layout


static func _layout_for(proto: Dictionary, proto_type: String) -> Dictionary:
	var type_name: String = str(proto.get("type", proto_type))

	match type_name:
		"furnace":
			return {
				INPUT: maxi(1, int(proto.get("source_inventory_size", 1))),
				OUTPUT: maxi(1, int(proto.get("result_inventory_size", 1))),
				FUEL: fuel_slots(proto),
			}
		"assembling-machine", "rocket-silo":
			return {
				INPUT: maxi(1, int(proto.get("ingredient_count", 0)) + 4),
				OUTPUT: 1,
				MODULES: int(proto.get("module_slots", 0)),
			}
		"mining-drill":
			return {OUTPUT: maxi(1, int(proto.get("result_inventory_size", 1)))}
		"lab":
			# One slot per science pack it accepts, plus the module slots;
			# Factorio lets a lab hold a couple of each.
			var packs: Variant = proto.get("inputs", [])
			var pack_slots: int = (packs as Array).size() * 2 if packs is Array else 4
			return {INPUT: maxi(4, pack_slots), MODULES: int(proto.get("module_slots", 0))}
		"boiler":
			return {FUEL: fuel_slots(proto)}
		"generator", "solar-panel", "accumulator":
			return {}
		"container":
			return {STORAGE: maxi(1, int(proto.get("inventory_size", 20)))}
		"logistic-container":
			return {STORAGE: maxi(1, int(proto.get("inventory_size", 20)))}
		"car", "spider-vehicle":
			return {STORAGE: maxi(1, int(proto.get("inventory_size", 20)))}
		"beacon":
			return {MODULES: int(proto.get("module_slots", 0))}
		"roboport":
			# The roboport's own buffer of spare robots and repair packs.
			return {STORAGE: int(proto.get("material_slots_count", 7))}
		"ammo-turret", "electric-turret", "fluid-turret", "artillery-turret":
			return {FUEL: int(proto.get("inventory_size", 1))}
		"reactor":
			return {FUEL: fuel_slots(proto)}
		_:
			return {}


## Storage tanks, pipes and the like are handled by the fluid system instead.
static func fuel_slots(proto: Dictionary) -> int:
	var source: Variant = proto.get("energy_source", {})
	if source is Dictionary and str(source.get("type", "")) == "burner":
		return maxi(1, int(source.get("fuel_inventory_size", 1)))
	return 0


## The inventory that inserters should put things into when no recipe decides.
static func default_input(proto_type: String) -> String:
	match proto_type:
		"furnace", "assembling-machine", "rocket-silo", "lab":
			return INPUT
		"container", "logistic-container", "car":
			return STORAGE
		"boiler", "reactor":
			return FUEL
		_:
			return OUTPUT


## The inventory an inserter should take from.
static func default_output(proto_type: String) -> String:
	match proto_type:
		"furnace", "assembling-machine", "mining-drill", "rocket-silo":
			return OUTPUT
		"container", "logistic-container", "car":
			return STORAGE
		_:
			return STORAGE


## Create the inventories an entity owns and store them in its state.
static func attach(entity: Entity) -> void:
	var layout := for_entity(entity)
	var inventories: Dictionary = entity.state.get("inventories", {})
	for key: String in layout:
		var size: int = int(layout[key])
		if size <= 0:
			continue
		if not inventories.has(key):
			inventories[key] = Inventory.new(size)
	entity.state["inventories"] = inventories


static func get_inventory(entity: Entity, key: String) -> Inventory:
	var inventories: Dictionary = entity.state.get("inventories", {})
	var inv: Variant = inventories.get(key)
	return inv if inv is Inventory else null
