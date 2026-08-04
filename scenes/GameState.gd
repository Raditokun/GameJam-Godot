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
## Emitted when the boss fight begins, carrying the spawned boss so a HUD can
## hook its health without knowing where it was spawned from.
signal boss_fight_started(boss: Node3D)

const BOSS_SCENE := "res://scenes/BossMage.tscn"
## Where the Archmage lands: the middle of the tabletop.
const BOSS_SPAWN := Vector3(50.5, 73.6, -4.5)
## The burst that marks his arrival, and how long it lives.
const BOSS_ENTRANCE_FX := "res://3DModels/Spell Effects (Free)/spell_effects/spell_2_impact.tscn"
const ENTRANCE_FX_LIFETIME := 1.2

enum Phase {
	## Building. Time-of-battle is not running, no enemies exist.
	PREPARATION,
	## Fighting. Enemies spawn, weapons work, obstacles are locked in place.
	ACTION,
}

var phase: Phase = Phase.PREPARATION
## Counts completed attempts -- handy for HUD readouts and for scaling waves.
var attempt := 1
## True while the Archmage duel is running, so the wave spawner and anything else
## that would flood the bench can stay out of it.
var boss_fight := false
## True while the kitchen prologue is running: the player is walking the kitchen
## at full size before the curse shrinks them onto the bench. The phase stays
## PREPARATION throughout (so no waves and no coins), but `PrepCamera` has to
## stand down or it would seize the camera and release the cursor -- see
## `PrepCamera._apply_phase()`.
var prologue_active := false
## Set by the main menu so the gameplay scene knows to open on the prologue.
## Running Main.tscn directly (F6) leaves this false and drops straight onto the
## bench, which is what every test and probe wants.
var prologue_requested := false


func _ready() -> void:
	# Phase keys have to work even while a weapon or the build controller is
	# swallowing input, so they are handled here rather than on the player.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("lock_in") and phase == Phase.PREPARATION:
		start_action()
	elif event.is_action_pressed("restart_round") and phase == Phase.ACTION:
		reset_round()
	elif event.is_action_pressed("toggle_action_phase"):
		# Enter flips whichever way the round currently is -- a test shortcut for
		# bouncing in and out of the fight without reaching for two keys.
		if phase == Phase.PREPARATION:
			start_action()
		else:
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
	# End any duel in progress. The bench is already stripped of props by
	# start_boss_fight(), so a retry lands the player on an empty table in
	# PREPARATION -- press F1 again to re-fight. Deliberately not auto-restarting
	# the boss: this is a debug entry point, and a silent respawn loop would be
	# harder to get out of than to get into.
	boss_fight = false
	for node in get_tree().get_nodes_in_group("boss"):
		if not node.is_queued_for_deletion():
			node.queue_free()
	phase = Phase.PREPARATION
	attempt += 1
	round_reset.emit()
	phase_changed.emit(phase)


## Clears the bench and puts the Archmage on it.
##
## **Entered by collecting all ten coins** -- `CoinSpawner` connects its
## `all_coins_collected` signal straight to this in its own `_ready()`. Clearing
## the table is therefore the reward for finishing the collection round, and the
## duel is the last act rather than a debug mode. Guarded against re-entry so a
## stray second emission cannot spawn two Archmages.
##
## Both clear-outs are by GROUP, so this needs no node paths into Main.tscn and
## keeps working whatever the layout is. The props go because the duel is a
## dodging fight in open space -- 500 pieces of clutter would make the leap
## unreadable and the orbs would detonate on scenery instead of reaching anyone.
func start_boss_fight() -> void:
	if boss_fight:
		return
	var tree := get_tree()
	if tree == null:
		return

	for node in tree.get_nodes_in_group("draggable"):
		if not node.is_queued_for_deletion():
			node.queue_free()
	for node in tree.get_nodes_in_group("enemies"):
		if not node.is_queued_for_deletion():
			node.queue_free()

	# ACTION first: it hands the weapons back and takes the cursor off the
	# build tool, and the boss's own logic assumes the fight is live.
	boss_fight = true
	if phase != Phase.ACTION:
		phase = Phase.ACTION
		phase_changed.emit(phase)

	# The entrance runs in two halves. First the staff, the bars and the narration
	# -- then a wait for that line to finish, and only then does the Archmage
	# appear. Spawning him immediately would have him casting over his own
	# introduction.
	var player: Node = null
	for node in tree.get_nodes_in_group("player"):
		player = node
		break
	if player != null and player.has_method("begin_boss_fight"):
		player.begin_boss_fight()
		var voice = player.get("voice")
		# Guarded: awaiting a signal that can never fire hangs forever, so a
		# missing or silent VoicePlayer must fall straight through to the spawn
		# rather than leaving the fight permanently un-started.
		if voice != null and voice.playing:
			await voice.finished

	# The round can be reset while the line plays -- reset_round() clears this.
	if not boss_fight:
		return

	var packed := load(BOSS_SCENE) as PackedScene
	if packed == null:
		push_warning("[GameState] boss scene missing: %s" % BOSS_SCENE)
		return
	var host := _spawn_host()
	if host == null:
		push_warning("[GameState] nowhere to spawn the boss -- no scene and no player")
		return
	var boss := packed.instantiate() as Node3D
	# Positioned before add_child so the boss's _ready() sees its real spot.
	boss.position = BOSS_SPAWN
	host.add_child(boss)
	_spawn_entrance_burst(host)

	if player != null and player.has_method("attach_boss"):
		player.attach_boss(boss)
	boss_fight_started.emit(boss)


## A spell burst at the Archmage's feet as he lands, so he arrives rather than
## simply existing. Reuses the impact rig the duel already loads.
func _spawn_entrance_burst(host: Node) -> void:
	var packed := load(BOSS_ENTRANCE_FX) as PackedScene
	if packed == null:
		return
	var burst := packed.instantiate() as Node3D
	host.add_child(burst)
	burst.global_position = BOSS_SPAWN
	# The rigs do not clean up after themselves.
	get_tree().create_timer(ENTRANCE_FX_LIFETIME).timeout.connect(burst.queue_free)


## Where to parent runtime spawns.
##
## `current_scene` is the obvious answer and the usual one, but it is only set
## for a scene the SceneTree itself loaded -- it is null for a scene a tool or a
## test hosted under the root by hand, and `current_scene.add_child()` then
## crashes. Falling back to the player's own parent lands the boss in the same
## scene either way.
func _spawn_host() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	if tree.current_scene != null:
		return tree.current_scene
	for node in tree.get_nodes_in_group("player"):
		var parent := (node as Node).get_parent()
		if parent != null:
			return parent
	return null


## Ends the prologue and hands the round back to the normal PREPARATION flow.
## Re-emits `phase_changed` so `PrepCamera` -- which stood down while the
## prologue ran -- picks the phase up and takes the camera as it normally would.
func end_prologue() -> void:
	if not prologue_active:
		return
	prologue_active = false
	phase = Phase.PREPARATION
	phase_changed.emit(phase)


func is_preparation() -> bool:
	return phase == Phase.PREPARATION


func is_action() -> bool:
	return phase == Phase.ACTION
