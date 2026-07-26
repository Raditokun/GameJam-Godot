extends Node
## Autoloaded, persisted player settings: mouse sensitivity and master volume.
##
## These live in an autoload rather than on the Player so the settings menu has
## a target that outlives any one scene, and so audio can be applied globally
## without walking the tree. Values are written to user://settings.cfg whenever
## the menu closes, and reloaded on launch.

## Emitted after any value changes, so listeners can refresh without polling.
signal changed

const SAVE_PATH := "user://settings.cfg"

## Sensitivity is a multiplier on top of Player.mouse_sensitivity, so 1.0 keeps
## the feel authored in the scene and the slider spans a familiar CS-style range.
const SENS_MIN := 0.1
const SENS_MAX := 5.0

var sensitivity := 1.0
var volume := 0.8


func _ready() -> void:
	# Settings must stay reachable while the tree is paused behind the menu.
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()


func set_sensitivity(value: float) -> void:
	sensitivity = clampf(value, SENS_MIN, SENS_MAX)
	changed.emit()


func set_volume(value: float) -> void:
	volume = clampf(value, 0.0, 1.0)
	_apply_volume()
	changed.emit()


## Drives the Master bus from the linear slider. Zero mutes the bus outright
## rather than leaning on linear_to_db(0), which returns -inf.
func _apply_volume() -> void:
	var bus := AudioServer.get_bus_index("Master")
	if bus < 0:
		return
	AudioServer.set_bus_mute(bus, volume <= 0.0)
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(volume, 0.0001)))


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("input", "sensitivity", sensitivity)
	cfg.set_value("audio", "volume", volume)
	cfg.save(SAVE_PATH)


## Reads the config back, falling back to the current defaults for anything
## missing or malformed, then pushes the audio value at the bus.
func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		sensitivity = clampf(float(cfg.get_value("input", "sensitivity", sensitivity)), SENS_MIN, SENS_MAX)
		volume = clampf(float(cfg.get_value("audio", "volume", volume)), 0.0, 1.0)
	_apply_volume()
	changed.emit()
