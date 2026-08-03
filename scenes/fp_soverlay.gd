extends CanvasLayer

func _ready():
	# Hide the counter by default when the game starts
	hide()

func _process(_delta):
	# Continuously update the label with the engine's current framerate
	$Label.text = "FPS: " + str(Engine.get_frames_per_second())
