extends Control

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _on_start_pressed() -> void:
	# This loads the game. 
	# Make sure the "Start" button's signal is connected to THIS function!
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_setting_pressed() -> void:
	# This loads the settings. 
	# Make sure the "Setting" button's signal is connected to THIS function!
	get_tree().change_scene_to_file("res://scenes/SettingsMenu.tscn")

func _on_credits_pressed() -> void:
	# FIXED CRASH: "sword.tscn" was deleted, so this would have broken the game.
	# It will now just print a message to the console until you make a real Credits scene.
	print("Credits button clicked! (Need to make a Credits.tscn)")
	# get_tree().change_scene_to_file("res://scenes/Credits.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()
