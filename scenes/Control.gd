extends Control
## Main menu flow.
##
## Three panels share the screen and only one is ever up:
##   MainButtons    -- Start / Setting / Credits / Exit
##   DifficultyPanel -- Easy / Medium / Hard / Back
##   How to PLay    -- the controls card, and the last step before the game runs
##
## Start -> DifficultyPanel -> How to Play -> Main.tscn. Picking a difficulty only
## RECORDS it and advances the panel; the scene change happens on the How to Play
## button, so the player can still back out of the difficulty screen without the
## game having started.

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
	_select_difficulty(GameSettings.Difficulty.EASY)


func _on_medium_pressed() -> void:
	_select_difficulty(GameSettings.Difficulty.MEDIUM)


func _on_hard_pressed() -> void:
	_select_difficulty(GameSettings.Difficulty.HARD)


## Records the choice and advances to the How to Play card. Deliberately does NOT
## start the game -- that only happens from How to Play, so Back is still a way
## out of the difficulty screen.
func _select_difficulty(difficulty: GameSettings.Difficulty) -> void:
	GameSettings.difficulty = difficulty
	difficulty_panel.visible = false
	howtoplay.visible = true


func _on_back_difficulty_pressed() -> void:
	difficulty_panel.visible = false
	main_buttons.visible = true


## The only route into the game.
##
## `prologue_requested` is what separates a real playthrough from running
## Main.tscn directly (F6): the flag makes the player open in the kitchen
## prologue, while a direct run drops straight onto the bench for testing.
## Setting it here rather than on the difficulty buttons means backing out of the
## difficulty screen cannot leave it armed.
func _start_game() -> void:
	GameState.prologue_requested = true
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_how_to_play_start_pressed() -> void:
	_start_game()
