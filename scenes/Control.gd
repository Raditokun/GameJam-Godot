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
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_setting_pressed() -> void:
	main_buttons.visible = false
	setting.visible = true

func _on_credits_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/credit_scene.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_exit_setting_pressed() -> void:
	main_buttons.visible = true
	setting.visible = false
