extends Control
@onready var main_buttons: VBoxContainer = $MainButtons
@onready var setting: Panel = $Setting
@onready var difficulty_panel: VBoxContainer = $DifficultyPanel
@onready var howtoplay: Panel = $"How to PLay"


func _ready() -> void:
	main_buttons.visible = true
	setting.visible = false
	difficulty_panel.visible = false
	howtoplay.visible = false
	


func _on_start_pressed() -> void:
	main_buttons.visible = false
	difficulty_panel.visible = true


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


func _on_easy_pressed() -> void:
	GameSettings.difficulty = GameSettings.Difficulty.EASY
	main_buttons.visible = false
	setting.visible = false
	difficulty_panel.visible = false
	howtoplay.visible = true


func _on_medium_pressed() -> void:
	GameSettings.difficulty = GameSettings.Difficulty.MEDIUM
	main_buttons.visible = false
	setting.visible = false
	difficulty_panel.visible = false
	howtoplay.visible = true


func _on_hard_pressed() -> void:
	GameSettings.difficulty = GameSettings.Difficulty.HARD
	main_buttons.visible = false
	setting.visible = false
	difficulty_panel.visible = false
	howtoplay.visible = true


func _on_back_difficulty_pressed() -> void:
	difficulty_panel.visible = false
	main_buttons.visible = true
