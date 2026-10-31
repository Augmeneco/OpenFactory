extends PanelContainer
## The current research project, pinned between the minimap and the hovered
## object's panel.  Factorio keeps this visible at all times: what is being
## studied and how far along it is.

const WIDTH := 248.0
const HEIGHT := 80.0

var research: Research

var _title: Label
var _detail: Label
var _percent: Label
var _bar: ProgressBar


func _init(research_: Research) -> void:
	research = research_


func _ready() -> void:
	custom_minimum_size = Vector2(WIDTH, HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := FactorioStyle.stylebox("inside_shallow_frame_with_padding",
		"default")
	if style == null:
		style = FactorioStyle.stylebox("frame", "default")
	if style != null:
		add_theme_stylebox_override("panel", style)

	var body := UiKit.column(2)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(body)

	var header := UiKit.row(4)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(22, 22)
	icon.size = Vector2(22, 22)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = FactorioAssets.prototype_icon(
		Prototypes.get_p("technology", "automation"), 64)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(icon)
	_title = UiKit.label("", "frame_subheading_label")
	_title.custom_minimum_size = Vector2(WIDTH - 52, 0)
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_title)
	body.add_child(header)

	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(WIDTH - 24, 10)
	_bar.max_value = 100.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.36, 0.82, 0.45, 0.95)
	_bar.add_theme_stylebox_override("fill", fill)
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0, 0, 0, 0.55)
	_bar.add_theme_stylebox_override("background", back)
	body.add_child(_bar)

	_detail = UiKit.label("", "label")
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.custom_minimum_size = Vector2(WIDTH - 24, 0)
	body.add_child(_detail)
	_percent = UiKit.label("", "label")
	_percent.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_percent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(_percent)
	reset_size()
	refresh()


func _process(_delta: float) -> void:
	if visible:
		refresh()


## Rebuild the two text lines; the bar value is just a float assignment.
func refresh() -> void:
	if research == null or _title == null:
		return
	if research.current.is_empty():
		_title.text = "Research"
		_detail.text = "Nothing being researched"
		_percent.text = ""
		_bar.value = 0.0
		return
	_title.text = Loc.proto_name("technology", research.current)
	var percent := research.progress() * 100.0
	_bar.value = percent
	_percent.text = "%.0f%%" % percent
	_detail.text = "%d / %d units" % [research.units_done,
		research.total_units()]
