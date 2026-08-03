extends RichTextLabel

# This allows you to tweak the speed in the Inspector without changing code
@export var scroll_speed: float = 60.0

func _ready():
	# Automatically snap the text just below the bottom edge of the screen when the scene starts
	position.y = get_viewport_rect().size.y

func _process(delta):
	# Subtracting from the Y position moves the text UP
	position.y -= scroll_speed * delta
	
	# Check if the text has completely scrolled off the top of the screen
	if position.y < -size.y:
		finish_credits()

func finish_credits():
	# You can choose what happens when the credits end here. 
	# For example, return to the main menu:
	print("Credits finished!")
	# get_tree().change_scene_to_file("res://Scenes/MainMenu.tscn")
