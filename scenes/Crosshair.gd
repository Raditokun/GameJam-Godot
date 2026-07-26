extends Control
## Classic four-stroke FPS crosshair, drawn straight to the HUD.
##
## Drawn rather than textured so length/gap/thickness stay tweakable from the
## inspector without touching art. The control is stretched over the whole
## viewport and the reticle is drawn at its centre, so it stays centred at any
## resolution. It hides itself whenever the mouse is released (i.e. while the
## settings menu is up), since a reticle under a visible cursor reads as a bug.

@export_group("Shape")
## Length of each stroke in pixels.
@export var stroke_length := 10.0:
	set(value):
		stroke_length = value
		queue_redraw()
## Empty space between the centre and the start of each stroke.
@export var gap := 5.0:
	set(value):
		gap = value
		queue_redraw()
## Stroke width in pixels. Odd values land off-pixel; even ones stay crisp.
@export var thickness := 2.0:
	set(value):
		thickness = value
		queue_redraw()
## Draws a filled pip at the exact centre.
@export var center_dot := true:
	set(value):
		center_dot = value
		queue_redraw()

@export_group("Colour")
@export var color := Color(0.2, 1.0, 0.4, 0.9):
	set(value):
		color = value
		queue_redraw()
## Dark border drawn behind the strokes so the reticle survives bright walls.
@export var outline_size := 1.0:
	set(value):
		outline_size = value
		queue_redraw()
@export var outline_color := Color(0, 0, 0, 0.75):
	set(value):
		outline_color = value
		queue_redraw()


func _ready() -> void:
	# Never eat clicks meant for the world or the menu underneath.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Keep ticking while the tree is paused so it hides the moment the menu opens.
	process_mode = Node.PROCESS_MODE_ALWAYS
	resized.connect(queue_redraw)


func _process(_delta: float) -> void:
	visible = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _draw() -> void:
	# Round the centre so strokes land on whole pixels instead of blurring.
	var mid := (size * 0.5).round()
	if outline_size > 0.0:
		for r in _stroke_rects(mid):
			draw_rect(r.grow(outline_size), outline_color)
	for r in _stroke_rects(mid):
		draw_rect(r, color)


## The four arms plus the optional centre pip, as rects around `mid`.
func _stroke_rects(mid: Vector2) -> Array[Rect2]:
	var half := thickness * 0.5
	var rects: Array[Rect2] = [
		Rect2(mid.x - gap - stroke_length, mid.y - half, stroke_length, thickness),  # left
		Rect2(mid.x + gap, mid.y - half, stroke_length, thickness),  # right
		Rect2(mid.x - half, mid.y - gap - stroke_length, thickness, stroke_length),  # up
		Rect2(mid.x - half, mid.y + gap, thickness, stroke_length),  # down
	]
	if center_dot:
		rects.append(Rect2(mid.x - half, mid.y - half, thickness, thickness))
	return rects
