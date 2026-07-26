extends CanvasLayer
## Pause/settings overlay, opened and closed with Escape.
##
## While it's up the whole tree is paused -- that's what stops the player moving
## and the pistol firing behind the menu, since both act from _process /
## _physics_process. This node opts out of the pause with PROCESS_MODE_ALWAYS so
## it can still read the Escape that closes it. Values are committed to disk on
## close rather than on every slider tick.
##
## Scene-internal nodes are reached with $ rather than exported NodePaths: node
## exports only resolve when the .tscn carries a node_paths= marker, which is
## easy to lose when scenes are hand-edited.

@onready var _sens_slider: HSlider = $Backdrop/Center/Panel/Margin/VBox/Grid/SensSlider
@onready var _sens_value: Label = $Backdrop/Center/Panel/Margin/VBox/Grid/SensValue
@onready var _vol_slider: HSlider = $Backdrop/Center/Panel/Margin/VBox/Grid/VolSlider
@onready var _vol_value: Label = $Backdrop/Center/Panel/Margin/VBox/Grid/VolValue
@onready var _resume_button: Button = $Backdrop/Center/Panel/Margin/VBox/Buttons/ResumeButton
@onready var _quit_button: Button = $Backdrop/Center/Panel/Margin/VBox/Buttons/QuitButton


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	_sens_slider.min_value = GameSettings.SENS_MIN
	_sens_slider.max_value = GameSettings.SENS_MAX
	_sens_slider.step = 0.05
	_vol_slider.min_value = 0.0
	_vol_slider.max_value = 1.0
	_vol_slider.step = 0.01

	_sens_slider.value_changed.connect(_on_sensitivity_changed)
	_vol_slider.value_changed.connect(_on_volume_changed)
	_resume_button.pressed.connect(close)
	_quit_button.pressed.connect(func() -> void: get_tree().quit())

	_pull_from_settings()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if visible:
			close()
		else:
			open()
		get_viewport().set_input_as_handled()


func open() -> void:
	# Re-read in case anything changed the values while the menu was closed.
	_pull_from_settings()
	visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_resume_button.grab_focus()


func close() -> void:
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	GameSettings.save_settings()


## Syncs the sliders to the stored values without letting their value_changed
## signals bounce straight back into GameSettings.
func _pull_from_settings() -> void:
	_sens_slider.set_value_no_signal(GameSettings.sensitivity)
	_vol_slider.set_value_no_signal(GameSettings.volume)
	_refresh_labels()


func _on_sensitivity_changed(value: float) -> void:
	GameSettings.set_sensitivity(value)
	_refresh_labels()


func _on_volume_changed(value: float) -> void:
	GameSettings.set_volume(value)
	_refresh_labels()


func _refresh_labels() -> void:
	_sens_value.text = "%.2f" % GameSettings.sensitivity
	_vol_value.text = "%d%%" % roundi(GameSettings.volume * 100.0)
