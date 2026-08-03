extends Control
@onready var main_buttons: VBoxContainer = $MainButtons
@onready var setting: Panel = $Setting

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	main_buttons.visible = true
	setting.visible = false 

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass

func _on_start_pressed() -> void:

	print("Setting Pressed")
	main_buttons.visible = false
	setting.visible = true 

func _on_setting_pressed() -> void:
	# This loads the settings. 
	# Make sure the "Setting" button's signal is connected to THIS function!
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_credits_pressed() -> void:
	# FIXED CRASH: "sword.tscn" was deleted, so this would have broken the game.
	# It will now just print a message to the console until you make a real Credits scene.
	print("Credits button clicked! (Need to make a Credits.tscn)")
	# get_tree().change_scene_to_file("res://scenes/Credits.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_exit_setting_pressed() -> void:
	_ready()
