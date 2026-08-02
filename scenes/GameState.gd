extends Node
## Round phase machine for Macro-Tactics: The Workbench Defense.
##
## The whole game is a die-and-retry sandbox loop:
##   PREPARATION -- no enemies, the player freely drags obstacles into a maze
##                  (this is the "Order" the player builds).
##   ACTION      -- layout is locked in, weapons come out, enemies flood the
##                  table (the "Disorder" they have to survive).
##   A death or a manual restart drops straight back to PREPARATION with the
##   layout left exactly as it was, so a failed maze can be tweaked and retried
##   in seconds. Resetting deliberately does NOT move the obstacles back.
##
## Autoloaded as `GameState`, so anything (player, weapons, obstacles, enemies)
## can ask what phase the round is in without wiring node paths across scenes.

## Emitted on every phase change, with the phase just entered.
signal phase_changed(new_phase: Phase)
## Emitted when a round resets, so spawners can clear out whatever is alive.
signal round_reset

enum Phase {
	## Building. Time-of-battle is not running, no enemies exist.
	PREPARATION,
	## Fighting. Enemies spawn, weapons work, obstacles are locked in place.
	ACTION,
}

var phase: Phase = Phase.PREPARATION
## Counts completed attempts -- handy for HUD readouts and for scaling waves.
var attempt := 1


func _ready() -> void:
	# Phase keys have to work even while a weapon or the build controller is
	# swallowing input, so they are handled here rather than on the player.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("lock_in") and phase == Phase.PREPARATION:
		start_action()
	elif event.is_action_pressed("restart_round") and phase == Phase.ACTION:
		reset_round()


## Locks the layout in and starts the fight.
func start_action() -> void:
	if phase == Phase.ACTION:
		return
	phase = Phase.ACTION
	phase_changed.emit(phase)


## Ends the attempt and hands control back to the builder. Called on death, on
## the restart key, and eventually on a failed defense.
func reset_round() -> void:
	if phase == Phase.PREPARATION:
		return
	phase = Phase.PREPARATION
	attempt += 1
	round_reset.emit()
	phase_changed.emit(phase)


func is_preparation() -> bool:
	return phase == Phase.PREPARATION


func is_action() -> bool:
	return phase == Phase.ACTION
