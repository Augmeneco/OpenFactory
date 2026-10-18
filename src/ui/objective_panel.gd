class_name ObjectivePanel
extends PanelContainer
## The current objective, in the corner of the screen.
##
## Factorio keeps its next objective in view and chimes when one is met; this is
## that line.  It sits under the debug text, fades in when the goal changes and
## stops showing entirely once the last one is done.

const FADE_SECONDS := 6.0

var objectives: Objectives

var _title: Label
var _detail: Label
var _progress: Label
var _age := 0.0


func _init(objectives_: Objectives) -> void:
	objectives = objectives_


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := FactorioStyle.stylebox("inside_shallow_frame_with_padding",
		"default")
	if style == null:
		style = FactorioStyle.stylebox("frame", "default")
	if style != null:
		add_theme_stylebox_override("panel", style)

	var column := UiKit.column(2)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)
	_progress = UiKit.label("", "frame_subheading_label")
	column.add_child(_progress)
	_title = UiKit.label("", "label")
	column.add_child(_title)
	_detail = UiKit.label("", "label")
	_detail.add_theme_color_override("font_color", Color(0.75, 0.78, 0.8))
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.custom_minimum_size = Vector2(320, 0)
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_detail)
	objectives.completed.connect(_on_completed)
	refresh()


func refresh() -> void:
	if objectives == null:
		return
	var step := objectives.current_step()
	if step.is_empty():
		visible = false
		return
	visible = true
	_progress.text = "Objective %d of %d" % [objectives.current + 1,
		objectives.total()]
	_title.text = str(step["title"])
	_detail.text = str(step["detail"])


## A goal was met: bring the panel back to full brightness so the change is
## noticed even if it was already on screen.
func _on_completed(index: int, _title: String) -> void:
	_age = 0.0
	refresh()


func _process(delta: float) -> void:
	if not visible:
		return
	_age += delta
	# A goal just met is shown at full strength for a while, then settles back
	# so it stops competing with the game.
	var alpha := 1.0
	if _age > FADE_SECONDS:
		alpha = 0.72
	modulate = Color(1, 1, 1, alpha)
