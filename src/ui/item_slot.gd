class_name ItemSlot
extends Button
## One inventory slot, drawn with Factorio's slot artwork.
##
## Shows the item icon, the stack count in the corner and (for machines) the
## crafting progress.  Left click picks the stack up onto the cursor, right
## click takes half, matching Factorio's inventory behaviour.

const SLOT_STYLE := "slot"

var inventory: Inventory
var slot_index: int = -1
var progress: float = -1.0        ## 0..1 crafting progress, negative for none
var empty_texture: Texture2D

var _icon: TextureRect
var _count: Label
var _progress_bar: ProgressBar

signal slot_clicked(slot: ItemSlot, button: int, shift: bool, ctrl: bool)


func _init(size := 40) -> void:
	custom_minimum_size = Vector2(size, size)
	focus_mode = Control.FOCUS_NONE
	clip_contents = true

	for state: String in ["default", "hovered", "clicked", "disabled"]:
		var box := FactorioStyle.stylebox(SLOT_STYLE, state)
		if box == null:
			continue
		var key: String = {"default": "normal", "hovered": "hover", "clicked": "pressed",
			"disabled": "disabled"}[state]
		add_theme_stylebox_override(key, box)
	set_meta("factorio_style", SLOT_STYLE)


func _ready() -> void:
	_icon = TextureRect.new()
	# Icons come out of the atlas at 64 px; the slot is smaller than that.
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon.offset_left = 2
	_icon.offset_top = 2
	_icon.offset_right = -2
	_icon.offset_bottom = -2
	add_child(_icon)

	_count = Label.new()
	_count.add_theme_font_override("font", FactorioStyle.font("default"))
	_count.add_theme_font_size_override("font_size", FactorioStyle.font_size("default"))
	_count.add_theme_color_override("font_color", Color(1, 1, 1))
	_count.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_count.add_theme_constant_override("outline_size", 4)
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count.set_anchors_preset(Control.PRESET_FULL_RECT)
	_count.offset_right = -3
	_count.offset_bottom = -1
	add_child(_count)

	_progress_bar = ProgressBar.new()
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(0, 6)
	_progress_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_progress_bar.offset_left = 3
	_progress_bar.offset_right = -3
	_progress_bar.offset_top = -9
	_progress_bar.offset_bottom = -3
	_progress_bar.visible = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.35, 0.85, 0.35, 0.95)
	_progress_bar.add_theme_stylebox_override("fill", fill)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0, 0, 0, 0.5)
	_progress_bar.add_theme_stylebox_override("background", back)
	add_child(_progress_bar)

	refresh()


func bind(inv: Inventory, index: int) -> ItemSlot:
	inventory = inv
	slot_index = index
	refresh()
	return self


func stack() -> Dictionary:
	if inventory == null or slot_index < 0 or slot_index >= inventory.slots.size():
		return {}
	var slot: Variant = inventory.slots[slot_index]
	if slot == null:
		return {}
	return slot


func refresh() -> void:
	if _icon == null:
		return
	var slot := stack()
	if slot.is_empty():
		_icon.texture = empty_texture
		_count.text = ""
		remove_meta("tooltip_card")
		tooltip_text = ""
	else:
		_icon.texture = FactorioAssets.prototype_icon(
			Prototypes.item_proto(str(slot["name"])))
		_count.text = str(int(slot["count"])) if int(slot["count"]) > 1 else ""
		set_meta("factorio_icon", str(slot["name"]))
		# Factorio draws its own card on hover; the layer picks this up.
		TooltipLayer.attach(self, Tooltips.item_card(str(slot["name"])))
	if progress >= 0.0:
		_progress_bar.visible = true
		_progress_bar.value = clampf(progress, 0.0, 1.0) * 100.0
	else:
		_progress_bar.visible = false


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if not button.pressed:
		return
	if button.button_index != MOUSE_BUTTON_LEFT \
			and button.button_index != MOUSE_BUTTON_RIGHT \
			and button.button_index != MOUSE_BUTTON_MIDDLE:
		return
	accept_event()
	slot_clicked.emit(self, button.button_index, button.shift_pressed, button.ctrl_pressed)
