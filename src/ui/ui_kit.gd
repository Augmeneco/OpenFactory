class_name UiKit
extends RefCounted
## Small constructors for Factorio-styled widgets.
##
## Every widget records the Factorio style it was built from in its metadata,
## which is what lets the offline UI preview reproduce the interface without a
## GPU (see ``tools/preview_ui.py``).


static func remember(control: Control, style_name: String, state := "default") -> Control:
	control.set_meta("factorio_style", style_name)
	control.set_meta("factorio_state", state)
	return control


## A named frame, optionally with a title bar like Factorio's windows.
static func frame(title := "", style_name := "frame") -> PanelContainer:
	var panel := PanelContainer.new()
	remember(panel, style_name)
	# Only hand Godot a box that exists.  `technology_gui_left_frame` and a few
	# others are not in the stylesheet, and passing the null it returns makes
	# the engine log a "Required object is null" error for every one.
	var style := FactorioStyle.stylebox(style_name)
	if style == null:
		style = FactorioStyle.stylebox("frame")
	if style != null:
		panel.add_theme_stylebox_override("panel", style)
	var pads := FactorioStyle.padding(style_name)
	panel.add_theme_constant_override("margin_left", int(pads["left"]))
	panel.add_theme_constant_override("margin_right", int(pads["right"]))
	panel.add_theme_constant_override("margin_top", int(pads["top"]))
	panel.add_theme_constant_override("margin_bottom", int(pads["bottom"]))

	if title.is_empty():
		return panel

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	panel.add_child(column)
	var heading := label(title, "frame_title")
	column.add_child(heading)
	column.add_child(hseparator())
	panel.set_meta("content", column)
	return panel


## The container children should be added to (the body of a titled frame).
static func body(panel: PanelContainer) -> Container:
	var content: Variant = panel.get_meta("content", null)
	if content is Container:
		return content
	return panel


static func label(text: String, style_name := "label") -> Label:
	var node := Label.new()
	node.text = text
	remember(node, style_name)
	node.add_theme_font_override("font", FactorioStyle.font(style_name))
	node.add_theme_font_size_override("font_size", FactorioStyle.font_size(style_name))
	node.add_theme_color_override("font_color",
		FactorioStyle.color(style_name, "font_color", Color(0.92, 0.92, 0.92)))
	return node


## The interface's own click, played at the listener so it never fades.
static func _play_click() -> void:
	FactorioAudio.play_utility("gui_click", FactorioAudio.listener)


static func button(text: String, style_name := "button") -> Button:
	var node := Button.new()
	node.text = text
	remember(node, style_name)
	# Every button in the interface makes the same click, taken from the
	# `left_click_sound` the button styles themselves declare.
	if not node.pressed.is_connected(_play_click):
		node.pressed.connect(_play_click)
	node.add_theme_font_override("font", FactorioStyle.font(style_name))
	node.add_theme_font_size_override("font_size", FactorioStyle.font_size(style_name))
	var pads := FactorioStyle.padding(style_name)
	for state: String in ["default", "hovered", "clicked", "disabled"]:
		var box := FactorioStyle.stylebox(style_name, state)
		if box == null:
			continue
		# Button content margins live on the style box in Godot 4.
		box.content_margin_left = pads["left"]
		box.content_margin_right = pads["right"]
		box.content_margin_top = pads["top"]
		box.content_margin_bottom = pads["bottom"]
		var key: String = {"default": "normal", "hovered": "hover", "clicked": "pressed",
			"disabled": "disabled"}[state]
		if box != null:
			node.add_theme_stylebox_override(key, box)
	node.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	node.add_theme_color_override("font_color",
		FactorioStyle.color(style_name, "default_font_color", Color(0.92, 0.92, 0.92)))
	node.add_theme_color_override("font_hover_color",
		FactorioStyle.color(style_name, "hovered_font_color", Color(1, 1, 1)))
	return node


static func hseparator(style_name := "line") -> Control:
	var line := Panel.new()
	line.custom_minimum_size = Vector2(0, 2)
	remember(line, style_name)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.75, 0.75, 0.75, 0.25)
	line.add_theme_stylebox_override("panel", box)
	return line


static func spacer(height: float) -> Control:
	var node := Control.new()
	node.custom_minimum_size = Vector2(0, height)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


static func grid(columns: int, separation := 4) -> GridContainer:
	var node := GridContainer.new()
	node.columns = columns
	node.add_theme_constant_override("h_separation", separation)
	node.add_theme_constant_override("v_separation", separation)
	return node


static func row(separation := 4) -> HBoxContainer:
	var node := HBoxContainer.new()
	node.add_theme_constant_override("separation", separation)
	return node


static func column(separation := 4) -> VBoxContainer:
	var node := VBoxContainer.new()
	node.add_theme_constant_override("separation", separation)
	return node


static func scroll(style_name := "scroll_pane") -> ScrollContainer:
	var node := ScrollContainer.new()
	remember(node, style_name)
	node.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	node.clip_contents = true
	return node


## Make a control cover its parent.
##
## Anchors do the whole job: Godot derives the rectangle from the parent (or
## the viewport, for a control under a CanvasLayer) and keeps it right when
## the window is resized or the parent gets its first layout pass.  Setting
## `size` here as well used to be the workaround for headless dumps, but on a
## live anchor it makes Godot warn and then override the value anyway, so the
## rectangle is left entirely to the layout system.
static func fill_parent(control: Control) -> Control:
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	control.set_meta("fill_parent", true)
	# The offline dump runs without a window: anchors still resolve against
	# the viewport, but the headless preview tooling also wants the rectangle
	# materialised immediately.  Live runs must not touch `size` here or Godot
	# warns and overrides it from the anchors.
	if DisplayServer.get_name() == "headless":
		var viewport := control.get_viewport()
		if viewport != null:
			control.size = viewport.get_visible_rect().size
	return control


## Re-apply ``fill_parent`` to a control and every marked descendant.
static func refill(control: Control) -> void:
	var viewport := control.get_viewport()
	if viewport == null:
		return
	if bool(control.get_meta("fill_parent", false)):
		control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for child in control.get_children():
		if child is Control:
			refill(child)


## An icon of an item prototype at a given pixel size.
static func icon(item_name: String, pixels := 40) -> TextureRect:
	var node := TextureRect.new()
	# The atlas icon is 64 px whatever size is asked for, so the control has to
	# be told to ignore it or it takes 64 px of the row.
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.texture = FactorioAssets.prototype_icon(Prototypes.item_proto(item_name), 64)
	node.custom_minimum_size = Vector2(pixels, pixels)
	node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	node.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.set_meta("factorio_icon", item_name)
	return node
