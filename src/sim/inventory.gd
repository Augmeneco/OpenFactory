class_name Inventory
extends RefCounted
## A slot based item inventory, following Factorio's rules.
##
## Each slot holds a single item kind up to its prototype's ``stack_size``.
## ``insert`` and ``extract`` return what could not be transferred rather than
## failing, which is how every transfer in Factorio behaves.

## Each entry is ``null`` or ``{"name": String, "count": int}``.
var slots: Array = []
var capacity: int = 0
## When set, only these item names are accepted (fuel slots, module slots...).
var filter: PackedStringArray = PackedStringArray()
## Restricts insertion to a single item kind, like a machine's recipe slots.
var locked_to: String = ""


func _init(size: int = 0) -> void:
	resize(size)


func resize(size: int) -> void:
	capacity = maxi(0, size)
	while slots.size() < capacity:
		slots.append(null)
	if slots.size() > capacity:
		slots.resize(capacity)


func accepts(item_name: String) -> bool:
	if item_name.is_empty():
		return false
	if not locked_to.is_empty() and locked_to != item_name:
		return false
	if not filter.is_empty() and not filter.has(item_name):
		return false
	return true


func stack_limit(item_name: String) -> int:
	return Prototypes.stack_size(item_name)


func total(item_name: String = "") -> int:
	var sum := 0
	for slot: Variant in slots:
		if slot == null:
			continue
		if item_name.is_empty() or slot["name"] == item_name:
			sum += int(slot["count"])
	return sum


func count_of(item_name: String) -> int:
	return total(item_name)


func is_empty() -> bool:
	for slot: Variant in slots:
		if slot != null:
			return false
	return true


func first_item() -> String:
	for slot: Variant in slots:
		if slot != null:
			return str(slot["name"])
	return ""


## Add items, returning how many did not fit.
func insert(item_name: String, amount: int) -> int:
	if amount <= 0 or not accepts(item_name):
		return amount
	var limit := stack_limit(item_name)
	var remaining := amount

	# Top up existing stacks first, exactly like Factorio's inserters do.
	for i in slots.size():
		if remaining <= 0:
			break
		var slot: Variant = slots[i]
		if slot == null or slot["name"] != item_name:
			continue
		var space: int = limit - int(slot["count"])
		if space <= 0:
			continue
		var moved: int = mini(space, remaining)
		slot["count"] = int(slot["count"]) + moved
		remaining -= moved

	for i in slots.size():
		if remaining <= 0:
			break
		if slots[i] != null:
			continue
		var moved: int = mini(limit, remaining)
		slots[i] = {"name": item_name, "count": moved}
		remaining -= moved

	return remaining


## Remove up to ``amount`` items, returning how many were actually removed.
func extract(item_name: String, amount: int) -> int:
	var remaining := amount
	for i in slots.size():
		if remaining <= 0:
			break
		var slot: Variant = slots[i]
		if slot == null or slot["name"] != item_name:
			continue
		var taken: int = mini(int(slot["count"]), remaining)
		slot["count"] = int(slot["count"]) - taken
		remaining -= taken
		if int(slot["count"]) <= 0:
			slots[i] = null
	return amount - remaining


## Take a whole stack out of the first non-empty slot.
func take_stack(item_name: String = "") -> Dictionary:
	for i in slots.size():
		var slot: Variant = slots[i]
		if slot == null:
			continue
		if not item_name.is_empty() and slot["name"] != item_name:
			continue
		var taken := {"name": str(slot["name"]), "count": int(slot["count"])}
		slots[i] = null
		return taken
	return {}


func peek(item_name: String = "") -> Dictionary:
	for slot: Variant in slots:
		if slot == null:
			continue
		if not item_name.is_empty() and slot["name"] != item_name:
			continue
		return {"name": str(slot["name"]), "count": int(slot["count"])}
	return {}


func has_at_least(requirements: Array) -> bool:
	for requirement: Dictionary in requirements:
		if count_of(str(requirement["name"])) < int(requirement["amount"]):
			return false
	return true


func can_accept(item_name: String, amount: int) -> int:
	if amount <= 0 or not accepts(item_name):
		return 0
	var limit := stack_limit(item_name)
	var space := 0
	for slot: Variant in slots:
		if slot == null:
			space += limit
		elif slot["name"] == item_name:
			space += maxi(0, limit - int(slot["count"]))
	return mini(space, amount)


func used_slots() -> int:
	var used := 0
	for slot: Variant in slots:
		if slot != null:
			used += 1
	return used


func free_slots() -> int:
	return capacity - used_slots()


## Reorder the player's stacks by Factorio's item group/subgroup order.  The
## player inventory uses this so raw materials, logistics and production do
## not end up interleaved by whatever order items happened to be picked up.
func sort_by_type() -> void:
	var stacks: Array = []
	for slot: Variant in slots:
		if slot != null:
			stacks.append(slot)
	stacks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ka := Prototypes.item_sort_key(str(a.get("name", "")))
		var kb := Prototypes.item_sort_key(str(b.get("name", "")))
		return ka < kb)
	for i in slots.size():
		slots[i] = stacks[i] if i < stacks.size() else null


func clear() -> void:
	for i in slots.size():
		slots[i] = null


func to_dict() -> Dictionary:
	return {"capacity": capacity, "locked_to": locked_to, "slots": slots.duplicate(true)}


func from_dict(data: Dictionary) -> void:
	resize(int(data.get("capacity", 0)))
	locked_to = str(data.get("locked_to", ""))
	var saved: Array = data.get("slots", [])
	for i in mini(saved.size(), slots.size()):
		slots[i] = saved[i]
