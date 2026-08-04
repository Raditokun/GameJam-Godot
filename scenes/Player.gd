extends CharacterBody3D
## Source-engine (Counter-Strike) style first-person controller.
##
## Movement mirrors Valve's CGameMovement: ground friction + linear
## acceleration toward a "wish" velocity, plus a separate air-acceleration
## step whose TARGET speed is hard-capped. That cap is what makes air-strafing
## and bunny-hopping possible: while airborne you keep adding speed along your
## wish direction as long as your velocity isn't already moving that way, so
## sweeping the mouse while holding a strafe key bleeds speed upward.
##
## Tunables are in metres (Godot units); comments note the Source cvar each
## one maps to.

# --- Look ---
@export_group("Look")
## Radians of rotation per pixel of mouse movement, at the settings menu's
## default sensitivity of 1.0. The menu scales this rather than replacing it.
@export var mouse_sensitivity := 0.003
## Maximum up/down look angle. Source clamps pitch to ~89 degrees.
@export_range(0.0, 90.0, 0.1) var pitch_limit_deg := 89.0


# --- Movement ---
@export_group("Movement")
## Target ground speed. Source: sv_maxspeed (~250 u/s).
@export var max_speed := 7.0
## Target speed while the walk key (Shift) is held. Source: +speed / cl_forwardspeed
## halving. Like Source this also damps air acceleration, so shift-strafing
## gains less speed -- that's authentic, not a bug.
@export var walk_speed := 3.5
## Ground acceleration multiplier. Source: sv_accelerate.
@export var ground_accel := 10.0
## Ground friction. Source: sv_friction.
@export var friction := 6.0
## Speed below which friction decays at a fixed rate. Source: sv_stopspeed.
@export var stop_speed := 2.0
## Air acceleration multiplier. Source: sv_airaccelerate.
@export var air_accel := 12.0
## Hard cap on the *target* air speed -- the heart of air-strafing.
## Source: sv_air_max_wishspeed (30 u/s).
@export var air_cap := 0.8
## Upward launch speed on jump. Peak height is jump_velocity^2 / (2 * gravity),
## so 6.5 with gravity 20 clears just over 1.0 m.
@export var jump_velocity := 6.5
## Downward acceleration. Source: sv_gravity (800 u/s^2).
@export var gravity := 20.0
## Hold jump to keep hopping (auto bunny-hop); if false, jump must be re-pressed.
@export var auto_bhop := true


# --- Crouch ---
@export_group("Crouch")
## Target ground speed while crouched (slower, like a ducked Source player).
@export var crouch_speed := 3.0
## Capsule height while crouched. Clamped to >= 2 * radius at runtime.
@export var crouch_height := 1.0
## Camera height (measured from the feet) while crouched.
@export var crouch_eye := 0.9
## How quickly the duck/stand transition plays out, in metres per second.
@export var crouch_transition_speed := 8.0
## Walking speed during the kitchen prologue, in 1x units per second. Half
## `max_speed`, because the prologue is a stroll up to a book, not a bunny-hop.
##
## **Multiplied by `PROLOGUE_SCALE` where it is applied**, because the player is
## 74.77x their normal size while walking the kitchen: a raw 3.5 u/s would take
## over three minutes to cross a 763-unit room.
@export var prologue_speed := 3.5


# --- Props ---
@export_group("Props")
## Shove strength when walking into a physics prop, in newton-seconds per
## metre-per-second of closing speed. Impulses scale with how fast you're
## actually moving into the prop, so a prop drifts when you lean on it and
## skids when you sprint into it.
##
## This has a hard floor to clear: each frame's impulse must beat the prop's
## static friction (mu * mass * g * delta) or it is absorbed entirely and the
## prop NEVER moves, however long you push. For the 25 kg table on a 0.6
## friction floor that threshold is ~2.5 N-s per frame, and walking into it at
## 7 m/s delivers push_force * 7 / 60. Lower this too far and props turn into
## walls; the symptom is a prop that ignores you and then lurches when you back
## away from it.
@export var push_force := 120.0
## How far the pickup ray reaches, in metres.
@export var carry_range := 3.0
## How far in front of the camera a carried prop is held, in metres. Held props
## are pulled in closer than this when a wall is in the way.
@export var carry_distance := 2.6
## Stiffness of the carry "spring", in 1/seconds: the held prop is driven at
## (offset to the hold point) * this. Higher snaps to the hold point harder.
@export var carry_stiffness := 12.0
## Ceiling on carry speed, in metres per second. Keeps a prop yanked around a
## corner from launching itself.
@export var carry_max_speed := 12.0
## Drop the prop once it ends up this far from the hold point -- i.e. it got
## wedged behind geometry and the carry spring can't reach it any more.
@export var carry_break_distance := 3.0
## Launch speed of a thrown prop, in metres per second. Converted to an impulse
## with the prop's own mass, so heavy props still leave the hands at this speed.
@export var throw_speed := 9.0


# --- Debug HUD ---
@export_group("Debug HUD")
## Source units per metre for the speed readout. A Source unit is one inch, so
## 39.37 makes max_speed 7.0 read as ~276 u/s. Use 35.7 to make it read 250.
@export var units_per_metre := 39.37

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var jump: AudioStreamPlayer3D = $jump
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var stats_label: Label = $HUD/StatsLabel
@onready var phase_label: Label = $HUD/PhaseLabel
@onready var you_died_label: Label = $HUD/YouDiedLabel
@onready var health_bar: ProgressBar = get_node_or_null("HUD/PlayerHealthBar") as ProgressBar
@onready var boss_health_bar: ProgressBar = get_node_or_null("HUD/BossHealthBar") as ProgressBar
## One player for all three narration beats -- see the VO_SCENE_* constants.
@onready var voice: AudioStreamPlayer = get_node_or_null("VoicePlayer") as AudioStreamPlayer
## Looping background music. One track at a time -- see _play_music().
@onready var music: AudioStreamPlayer = get_node_or_null("MusicPlayer") as AudioStreamPlayer
## The game's one sound-effect mixer. Everything that makes a noise routes
## through play_sfx() rather than carrying its own player -- see _setup_sfx().
@onready var sfx: AudioStreamPlayer = get_node_or_null("SFXPlayer") as AudioStreamPlayer
## Build-phase instructions. See _update_prep_tutorial().
@onready var _prep_tutorial: Control = get_node_or_null("HUD/PrepTutorialPanel") as Control
# Weapon slots in order: slot 1, slot 2. Reached with $ rather than exported
# NodePaths because both live inside this scene; node exports only resolve when
# the .tscn carries a node_paths= marker, which is easy to lose by hand.
@onready var weapons: Array[Node3D] = [
	$Head/Camera3D/Pistol,
	$Head/Camera3D/StaffQuartz,
]

var _pitch := 0.0
var _crouching := false
# Index into `weapons` of the weapon currently in hand.
var _slot := 0
# True once the current jump/ground-contact has already played its SFX, so the
# sound fires once per hop instead of every physics frame Space is held.
var _jumped := false
var _was_grounded := true

# Air-strafe scoring: speed actually gained vs. the most a perfect strafe could
# have gained, accumulated over the current airborne stretch. See _measure_air_gain().
var _gain_actual := 0.0
var _gain_ideal := 0.0
var _gain_pct := 0.0

# Per-instance copies of the capsule shape + mesh so runtime crouch resizing
# never mutates the shared sub-resources. Populated in _ready().
var _capsule: CapsuleShape3D
var _mesh_capsule: CapsuleMesh
var _stand_hull: CapsuleShape3D
var _stand_height := 1.8
var _stand_eye := 1.6

# The prop currently in hand (null when empty-handed), and the weapon slot to
# put back once it's dropped -- carrying holsters whatever was equipped.
var _carried: Prop = null
var _stowed_slot := 0

# Pose the player is returned to when a round resets.
var _spawn_transform := Transform3D.IDENTITY

## Index of the Staff of Quartz in `weapons`. Named so the boss-fight handover
## does not hard-code a bare 1.
const STAFF_SLOT := 1

## Scale the player wears during the kitchen prologue.
##
## The same 74.76889 the `Kitchen` and `meja` instances carry. At 1x the player is
## an insect in a 763-unit room and the cursed book -- 26 units wide, 72 units off
## the floor -- is an unreachable monolith; at this scale the book is 0.35 m and
## sits at waist height, i.e. a real book in a real kitchen. The curse then
## shrinks them to 1x, which is what makes the bench enormous.
const PROLOGUE_SCALE := 74.76889
## Where the prologue starts: on the kitchen floor (top y = 0), a few strides
## back from the book so the player walks up to it.
const PROLOGUE_SPAWN := Vector3(59.5, 8.0, -180.0)
## Seconds the fade to and from black takes.
const FADE_TIME := 0.9
## How far the book marker rises and falls, in world units. 0.6 rather than a
## few centimetres because the book beside it is 26 units wide.
const BOOK_PROMPT_BOB := 0.6
## Radians per millisecond for that bob -- a full cycle just over 2 s.
const BOOK_PROMPT_BOB_RATE := 0.003

## The three narration beats, in the order the player meets them: the curse, the
## Archmage's entrance, and the ending. All played through one AudioStreamPlayer
## so a new line always cuts the previous one off rather than overlapping it.
const VO_SCENE_1 := preload("res://Sounds/scene 1.mp3")
const VO_SCENE_2 := preload("res://Sounds/scene 2.mp3")
const VO_SCENE_3 := preload("res://Sounds/scene 3.mp3")

## The two looping background tracks the bench can run under, and the one the
## Archmage brings with him. EASY and MEDIUM share `BGM_EZDIF`; HARD gets its own
## track to go with the blackout. All three are started by _play_music(), which is
## also what turns looping on -- they import with `loop = false`.
const BGM_EZDIF := preload("res://Sounds/ezdif.mp3")
const BGM_HARD := preload("res://Sounds/hard.mp3")
const BGM_BOSS := preload("res://Sounds/boss.mp3")

## The death sting. Played by die(), which is idempotent, so a whole swarm
## arriving on the same frame gets one jumpscare rather than a wall of them.
const SFX_FAH := preload("res://Sounds/fah.mp3")

## Groups the victory sweep uses to shut the swarm down. Matching `WaveSpawner`'s
## own `enemy_group` and `spawner_group` exports.
const ENEMY_GROUP := "enemies"
const WAVE_SPAWNER_GROUP := "wave_spawner"

## The ending card. Shown in the same gold Dimbo as the curse.
const VICTORY_TEXT := "THE END\n(See you next time...)\n\n[Press Space to Return to Main Menu]"
const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

## Height below which the player has fallen off the bench and dies. The tabletop
## is at y ~= 73.6 and the kitchen floor is at y = 0, so there is a wide dead band
## between "standing on the bench" and "falling". Matches the threshold
## PrepCamera and Enemy use to despawn fallen props and enemies.
const FALL_DEATH_Y := 65.0

## Hit points. Only the Archmage's spells spend these — a minion that reaches the
## player kills outright, so this is the boss fight's own damage model rather
## than a general health system.
var health := 100.0
var max_health := 100.0

## True while the kitchen prologue is running. Suppresses the fall-death check
## (the kitchen floor is 73 units below the bench, which would otherwise read as
## having fallen off it) and keeps the combat HUD off screen.
var is_prologue := false
## True between inspecting the book and pressing Space: movement is frozen and
## the curse subtitle is up.
var _in_curse_blackout := false
## Movement tunables at 1x, captured before the prologue scales them up.
var _base_movement := {}
## True from the Archmage's death until the player returns to the menu. Freezes
## movement and turns Space into "back to the main menu".
var _in_victory := false

## The cursed book and its floating marker, both resolved once at prologue start.
var _book: Node = null
var _book_prompt: Label3D = null
var _book_prompt_rest_y := 0.0

## True from the moment an enemy reaches the player until they retry. Gates
## movement and every input except the two retry keys.
var is_dead := false
## Current camera shake amplitude, decaying to zero. Set by die().
var _shake_intensity := 0.0

## The SFXPlayer's polyphonic mixer, resolved once in _setup_sfx(). Null means
## sound effects degrade to silence rather than erroring on every shot.
var _sfx_playback: AudioStreamPlaybackPolyphonic = null


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Take private copies of the collision/visual capsules so crouch resizing is
	# local to this instance (safe if the Player scene is instanced more than once).
	_capsule = collision_shape.shape.duplicate()
	collision_shape.shape = _capsule
	_mesh_capsule = mesh.mesh.duplicate()
	mesh.mesh = _mesh_capsule
	# The scene's authored dimensions are our "standing" targets.
	_stand_height = _capsule.height
	_stand_eye = head.position.y
	# A standing-size probe reused to test for headroom before un-crouching.
	_stand_hull = CapsuleShape3D.new()
	_stand_hull.radius = _capsule.radius
	_stand_hull.height = _stand_height
	# Where a failed attempt puts the player back. Captured before anything can
	# move them, so every retry starts from the same spot.
	_spawn_transform = global_transform
	GameState.phase_changed.connect(_on_phase_changed)
	# Death state is cleared by the round reset itself, not only by _respawn().
	# Anything that resets the round -- the G key straight through GameState, a
	# future breached-defence trigger -- has to clear the death screen too, or the
	# player ends up alive and mobile behind a "YOU DIED" overlay.
	GameState.round_reset.connect(_on_round_reset)
	# Start on slot 1. This also drives the initial visibility of both weapons,
	# overriding whatever `visible` the scene was saved with.
	equip(0)
	_on_phase_changed(GameState.phase)
	if you_died_label != null:
		you_died_label.visible = false
	health = max_health
	_update_health_bar()
	_set_health_bar_visible(false)
	apply_environment_lighting()
	_setup_sfx()
	if GameState.prologue_requested:
		# Consumed, so a later reset or scene reload does not replay the prologue.
		GameState.prologue_requested = false
		_begin_prologue.call_deferred()
	else:
		# No prologue to wait for -- running Main.tscn directly (F6) is already
		# tabletop play, so the bench track starts here instead of at the curse.
		play_tabletop_music()


## Puts the player in the kitchen at full size, before the curse.
##
## Deferred from _ready so it wins over PrepCamera, which also applies the phase
## on a deferred call and would otherwise take the camera back.
func _begin_prologue() -> void:
	is_prologue = true
	GameState.prologue_active = true

	# Scale the body AND its movement together. Speeds and gravity are in units
	# per second, so leaving them at 1x values would have a 134-unit-tall figure
	# creeping across the room at a crawl.
	_base_movement = {
		"max_speed": max_speed, "walk_speed": walk_speed,
		"crouch_speed": crouch_speed, "jump_velocity": jump_velocity,
		"gravity": gravity, "scale": scale,
	}
	scale = Vector3.ONE * PROLOGUE_SCALE
	max_speed *= PROLOGUE_SCALE
	walk_speed *= PROLOGUE_SCALE
	crouch_speed *= PROLOGUE_SCALE
	jump_velocity *= PROLOGUE_SCALE
	gravity *= PROLOGUE_SCALE

	global_position = PROLOGUE_SPAWN
	velocity = Vector3.ZERO
	_set_combat_hud_visible(false)
	# is_prologue is set above, so this holsters everything.
	equip(_slot)
	# First person, cursor captured -- PrepCamera stands down for the prologue.
	camera.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Re-applied now that is_prologue is set: _ready() runs this before the
	# deferred call that gets here, so on HARD it would already have blacked the
	# kitchen out.
	apply_environment_lighting()

	_book = _find_book()
	if _book != null and _book.has_signal("book_inspected"):
		_book.book_inspected.connect(_on_book_inspected, CONNECT_ONE_SHOT)

	var host: Node = get_tree().current_scene
	if host == null:
		host = get_parent()
	if host != null:
		_book_prompt = host.find_child("BookPromptLabel", true, false) as Label3D
	if _book_prompt != null:
		_book_prompt_rest_y = _book_prompt.position.y


## Shows the build-phase instructions, and only then.
##
## Up during PREPARATION, down during the prologue (the player is a full-size
## person in a kitchen, with no maze to build), during ACTION, during the duel and
## behind the ending card. Driven from `_process` rather than from the four or
## five places those states change, because one missed call site leaves a
## tutorial panel sitting over the boss fight.
func _update_prep_tutorial() -> void:
	if _prep_tutorial == null:
		return
	_prep_tutorial.visible = (
		GameState.is_preparation()
		and not is_prologue
		and not GameState.boss_fight
		and not _in_victory
		and not is_dead
	)


## Shows the floating "[E] Open Book" marker while the player is near the book
## during the prologue, and floats it gently so it catches the eye.
##
## The label lives in `Main.tscn` (`BookPromptLabel`), not in `buku.tscn`, so it
## is positioned in world space next to the book rather than inside the book's
## own oddly-offset local frame. `Buku` only reports whether someone is close;
## this decides whether the label is up.
func _update_book_prompt() -> void:
	if _book_prompt == null:
		return
	# Typed explicitly: is_player_near() is a dynamic call on an untyped Node, so
	# inference fails and the whole script refuses to parse.
	var show_it: bool = is_prologue and not _in_curse_blackout \
		and _book != null and is_instance_valid(_book) and _book.is_player_near()
	_book_prompt.visible = show_it
	if not show_it:
		return
	# Clock-driven rather than accumulated, so it cannot drift out of phase.
	_book_prompt.position.y = _book_prompt_rest_y \
		+ sin(Time.get_ticks_msec() * BOOK_PROMPT_BOB_RATE) * BOOK_PROMPT_BOB


func _find_book() -> Node:
	var host: Node = get_tree().current_scene
	if host == null:
		host = get_parent()
	if host == null:
		return null
	return host.find_child("Buku", true, false)


## Everything that belongs to the bench fight, hidden while the prologue runs.
func _set_combat_hud_visible(shown: bool) -> void:
	# PhaseLabel and StatsLabel are deliberately absent: both are debug readouts
	# that ship hidden, and listing them here would switch them back on when the
	# prologue ends.
	for path in ["HUD/Minimap", "HUD/Crosshair", "HUD/GunBar", "HUD/StaffBar"]:
		var node := get_node_or_null(path) as CanvasItem
		if node != null:
			node.visible = shown
	# The coin readout lives in Main.tscn's own RoundUI, not on this HUD.
	var host: Node = get_tree().current_scene
	if host == null:
		host = get_parent()
	if host != null:
		var coin_label := host.find_child("CoinLabel", true, false) as CanvasItem
		if coin_label != null:
			coin_label.visible = shown


## The book has been read. Freeze, fade to black, and put the curse on screen.
func _on_book_inspected() -> void:
	if _in_curse_blackout:
		return
	_in_curse_blackout = true
	velocity = Vector3.ZERO

	var coins := 5 if GameSettings.difficulty == GameSettings.Difficulty.EASY else 10
	var subtitle := get_node_or_null("HUD/SubtitleLabel") as Label
	var overlay := get_node_or_null("HUD/BlackOverlay") as ColorRect
	if overlay != null:
		create_tween().tween_property(overlay, "color:a", 1.0, FADE_TIME)
	if subtitle != null:
		subtitle.text = (
			"You have been cursed! Hahaha! Collect all %d of my lost coins "
			+ "if you ever wish to return to your normal size!\n\n"
			+ "[Press Space to Continue]"
		) % coins
		subtitle.visible = true
	# Released so the fade is readable without the cursor trapped, and because
	# nothing needs mouse-look while the screen is black.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_play_voice(VO_SCENE_1)


## Plays one narration line, cutting off whatever was playing. Guarded so a
## missing VoicePlayer degrades to silence rather than crashing the beat it is
## attached to.
func _play_voice(stream: AudioStream) -> void:
	if voice == null or stream == null:
		return
	voice.stop()
	voice.stream = stream
	voice.play()


## Cuts the current narration line short. Used when the player dismisses the
## screen a line belongs to before that line has finished.
func _stop_voice() -> void:
	if voice != null:
		voice.stop()


## Prepares the shared sound-effect mixer.
##
## `max_polyphony = 16` on its own is NOT enough, and this is the whole reason the
## node carries an `AudioStreamPolyphonic`. Measured: `AudioStreamPlayer.set_stream()`
## calls `stop()`, so assigning a different sound cuts the previous one dead --
## max_polyphony only ever overlaps repeats of the SAME stream. One shared player
## has to carry the cannon, both staff attacks and a coin pickup at once, so the
## stream is a polyphonic mixer and each effect is pushed into it as its own voice.
##
## The mixer never ends, so the player stays `playing` for the whole session and
## the playback handle stays valid.
func _setup_sfx() -> void:
	if sfx == null:
		return
	# Authored in Player.tscn; rebuilt here so a hand-stripped scene still works.
	var poly := sfx.stream as AudioStreamPolyphonic
	if poly == null:
		poly = AudioStreamPolyphonic.new()
		poly.polyphony = maxi(sfx.max_polyphony, 1)
		sfx.stream = poly
	sfx.play()
	_sfx_playback = sfx.get_stream_playback() as AudioStreamPlaybackPolyphonic


## Plays one sound effect. Public because the weapons and the coin spawner all
## share this one player -- they find it by walking up the tree or by the `player`
## group and call this through `has_method()`, so nothing outside needs a node
## path into the Player scene.
func play_sfx(stream: AudioStream) -> void:
	if stream == null or _sfx_playback == null:
		return
	_sfx_playback.play_stream(stream)


## Starts the bench track for the current difficulty: HARD gets its own, EASY and
## MEDIUM share the other. Called when tabletop play actually begins -- the end of
## the prologue, or `_ready()` when there is no prologue to wait for.
func play_tabletop_music() -> void:
	_play_music(
		BGM_HARD if GameSettings.difficulty == GameSettings.Difficulty.HARD else BGM_EZDIF
	)


## Swaps the bench track for the Archmage's. Called from `attach_boss()`, i.e.
## after `scene 2.mp3` has finished and the boss is really on the table -- not
## from `begin_boss_fight()`, which runs while the narration is still playing.
func play_boss_music() -> void:
	_play_music(BGM_BOSS)


func stop_music() -> void:
	if music != null:
		music.stop()


## Puts one looping track on the music player, replacing whatever was there.
##
## Re-requesting the track already playing is a no-op: restarting it would drop a
## gap into a loop the player is listening to for the whole round.
func _play_music(stream: AudioStream) -> void:
	if music == null or stream == null:
		return
	if music.stream == stream and music.playing:
		return
	# All three tracks import with `loop = false`, so without this each one plays
	# through once and the game falls silent. Set on the stream resource rather
	# than in the .import files, which the editor rewrites on re-import.
	var mp3 := stream as AudioStreamMP3
	if mp3 != null:
		mp3.loop = true
	music.stop()
	music.stream = stream
	music.play()


## Space. The curse lands: shrink to 1x, drop onto the bench, hand the round to
## the normal PREPARATION flow.
func _end_prologue() -> void:
	_in_curse_blackout = false
	is_prologue = false
	# The curse lands here: on HARD this is the moment the lights go out.
	apply_environment_lighting()

	var subtitle := get_node_or_null("HUD/SubtitleLabel") as Label
	if subtitle != null:
		subtitle.visible = false
	var overlay := get_node_or_null("HUD/BlackOverlay") as ColorRect
	if overlay != null:
		create_tween().tween_property(overlay, "color:a", 0.0, FADE_TIME)

	# Back to miniature, with the movement tunables restored to their 1x values.
	if not _base_movement.is_empty():
		scale = _base_movement["scale"]
		max_speed = _base_movement["max_speed"]
		walk_speed = _base_movement["walk_speed"]
		crouch_speed = _base_movement["crouch_speed"]
		jump_velocity = _base_movement["jump_velocity"]
		gravity = _base_movement["gravity"]
		_base_movement = {}

	# The spawn pose captured in _ready() is the tabletop one, which is exactly
	# where the shrunken player belongs.
	global_transform = _spawn_transform
	velocity = Vector3.ZERO
	_set_combat_hud_visible(true)
	equip(_slot)
	# Tabletop play begins here, so this is where the bench track comes in -- the
	# kitchen runs under the curse narration alone.
	play_tabletop_music()
	# Hands the camera and the cursor to PrepCamera and starts the build phase.
	GameState.end_prologue()



## Sets the world lighting for the current difficulty AND the current stage of the
## round. Called on load and again the moment the prologue ends.
##
## HARD's pitch-black is **deferred until after the curse**. Applying it at load
## would leave the player groping around an unlit kitchen for a book they cannot
## see, and would spend the reveal before the game has started. Lit kitchen, then
## the curse, then darkness.
##
## Both branches set every property the other touches: the `Environment` is a
## single shared resource that survives the switch, so a branch that only sets
## half its state leaves the other half behind.
func apply_environment_lighting() -> void:
	var flashlight := get_node_or_null("Head/Camera3D/Flashlight") as Light3D
	# `current_scene` is null for a scene hosted by hand rather than loaded by the
	# SceneTree, and find_child() on null crashes _ready() outright -- which takes
	# the rest of the player's setup down with it. Fall back to our own parent,
	# which is the Main root either way.
	var host: Node = get_tree().current_scene
	if host == null:
		host = get_parent()
	if host == null:
		return
	var dir_light := host.find_child("DirectionalLight3D", true, false) as DirectionalLight3D
	var world_env := host.find_child("WorldEnvironment", true, false) as WorldEnvironment

	# Daylight while the prologue runs, whatever the difficulty. The kitchen has to
	# be lit for the player to find the book -- HARD's darkness is the curse's
	# doing, so it lands with the curse and not before.
	if is_prologue or GameSettings.difficulty != GameSettings.Difficulty.HARD:
		if dir_light != null:
			dir_light.visible = true
			dir_light.light_energy = 1.0
		if world_env != null and world_env.environment != null:
			var env := world_env.environment
			env.background_mode = Environment.BG_SKY
			env.ambient_light_source = Environment.AMBIENT_SOURCE_BG
			# Restored too: the dark branch drops this to 0.02, and the Environment
			# is one shared resource that outlives the switch. Without this a
			# daylight pass after a dark one leaves the world unlit.
			env.ambient_light_energy = 1.0
		if flashlight != null:
			flashlight.visible = false
		return

	# HARD, on the bench, after the curse: pitch dark but for the flashlight.
	if dir_light != null:
		dir_light.visible = false
	if world_env != null and world_env.environment != null:
		var env := world_env.environment
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.005, 0.005, 0.015, 1.0)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.01, 0.01, 0.02, 1.0)
		env.ambient_light_energy = 0.02
	if flashlight != null:
		flashlight.visible = true


## Spends health, shakes the camera, and dies at zero. Called by the Archmage's
## spells through has_method(), so nothing on the boss side knows the player type.
##
## Note a minion reaching the player still calls die() directly and ignores this:
## contact with the swarm is lethal by design, and routing it through health
## would mean surviving a skeleton that has already caught you.
func take_damage(amount: float) -> void:
	if is_dead or amount <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	_update_health_bar()
	# Scaled by the size of the hit, so a splash graze reads differently from a
	# direct spell to the chest.
	shake(clampf(0.25 + amount / 100.0, 0.25, 0.9))
	if health <= 0.0:
		die()


## Adds camera shake without overwriting a bigger one already running.
## Public so the boss can call it on a cast or a landing.
func shake(amount: float) -> void:
	_shake_intensity = maxf(_shake_intensity, amount)


## Called by GameState when the Archmage spawns: hands over the Staff of Quartz
## and raises the boss health bar, following the boss's own health signal so the
## bar needs no per-frame polling.
## The Archmage's entrance, part one: everything that happens *before* he is on
## the table. Hands over the staff, raises both bars, and starts the narration.
##
## Split from `attach_boss()` because the boss is deliberately not spawned until
## `scene 2.mp3` has finished -- the arrival lands on the end of the line rather
## than talking over it.
func begin_boss_fight() -> void:
	equip(STAFF_SLOT)
	health = max_health
	_update_health_bar()
	# The duel is the only thing that spends health, so this is where the bar
	# earns its place on screen.
	_set_health_bar_visible(true)
	# The bench track ends the moment the Archmage is announced, so his
	# introduction plays into silence. attach_boss() brings BGM_BOSS in at the end
	# of the line, which leaves the narration as the whole transition between the
	# two tracks rather than a crossfade over one of them.
	stop_music()
	_play_voice(VO_SCENE_2)
	if boss_health_bar != null:
		# Full, using the bar's authored maximum. attach_boss() corrects it from
		# the real boss once he exists, which is what makes EASY's lower total
		# show properly.
		boss_health_bar.visible = true
		boss_health_bar.value = boss_health_bar.max_value


## Part two: the boss has arrived, so point the bar at him.
func attach_boss(boss: Node) -> void:
	# The duel's track takes over here rather than in begin_boss_fight(): this runs
	# once `scene 2.mp3` has finished, so the swap lands on the Archmage's arrival
	# instead of playing under his introduction. Ahead of the guard below, since the
	# music should change whether or not there is a health bar to wire up.
	play_boss_music()
	if boss_health_bar == null or boss == null or not is_instance_valid(boss):
		return
	boss_health_bar.visible = true
	if "max_health" in boss:
		boss_health_bar.max_value = boss.max_health
		boss_health_bar.value = boss.max_health
	if boss.has_signal("health_changed"):
		boss.health_changed.connect(_on_boss_health_changed)
	if boss.has_signal("died"):
		boss.died.connect(_on_boss_died)


func _on_boss_health_changed(current: float, maximum: float) -> void:
	if boss_health_bar == null:
		return
	boss_health_bar.max_value = maximum
	boss_health_bar.value = current


## The Archmage is down. Freeze the player, let the closing narration run to the
## end, then fade to black and put the ending card up.
##
## Awaits `voice.finished` rather than a fixed delay so the fade always lands on
## the last word however long the recording is. If there is no player or no
## stream the await would hang forever, so both are checked first -- a missing
## audio file must not soft-lock the ending.
func _on_boss_died() -> void:
	if boss_health_bar != null:
		boss_health_bar.visible = false
	if _in_victory:
		return
	_in_victory = true
	velocity = Vector3.ZERO
	# The fight is won, so nothing hostile survives it. Without this any minion
	# still on the bench keeps hunting a player who is frozen and unarmed behind
	# the ending card -- and its contact kill would put "YOU DIED" over the
	# victory screen.
	_end_the_swarm()
	_set_combat_hud_visible(false)
	_set_health_bar_visible(false)
	for weapon in weapons:
		if is_instance_valid(weapon):
			weapon.equipped = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# The fight is over, so its music goes with it -- the closing line and the
	# ending card play out in silence rather than over a battle loop.
	stop_music()

	_play_voice(VO_SCENE_3)
	if voice != null and voice.playing:
		await voice.finished

	# The player may have retried out of the fight while the line played.
	if not _in_victory:
		return
	var overlay := get_node_or_null("HUD/BlackOverlay") as ColorRect
	if overlay != null:
		var tween := create_tween()
		tween.tween_property(overlay, "color:a", 1.0, FADE_TIME)
		await tween.finished
	if not _in_victory:
		return
	var subtitle := get_node_or_null("HUD/SubtitleLabel") as Label
	if subtitle != null:
		subtitle.text = VICTORY_TEXT
		subtitle.visible = true


## Shuts the swarm down permanently: stops every wave spawner, then sweeps the
## board for anything the spawners do not own.
##
## The spawner goes first. Freeing the minions before stopping the clock leaves a
## timer that can fire on a later frame and repopulate an arena the player has
## already won, which is precisely the bug this is meant to prevent.
##
## Both lookups are by GROUP -- the spawner lives in `Main.tscn` and the Player is
## an instance inside it, so there is no stable path between them -- and the
## spawner is called through `has_method()`, so a scene without one still clears
## its enemies.
func _end_the_swarm() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for node in tree.get_nodes_in_group(WAVE_SPAWNER_GROUP):
		if node.has_method("stop_waves"):
			node.stop_waves()
	# The backstop: hand-placed enemies, and anything a spawner never adopted.
	# Guarded on is_queued_for_deletion() because a freed node stays in its group
	# until the end of the frame, and stop_waves() has just queued most of these.
	for node in tree.get_nodes_in_group(ENEMY_GROUP):
		if not node.is_queued_for_deletion():
			node.queue_free()


func _update_health_bar() -> void:
	if health_bar == null:
		return
	health_bar.max_value = max_health
	health_bar.value = health


## The health bar belongs to the Archmage duel and nothing else.
##
## Health is only ever spent by his spells -- a minion that reaches the player
## kills outright -- so a permanently visible 100/100 bar would be HUD noise
## through the entire build-and-survive loop, and would imply a damage model the
## rest of the game does not have.
func _set_health_bar_visible(shown: bool) -> void:
	if health_bar != null:
		health_bar.visible = shown


## Called by an enemy that has reached the player. Idempotent -- a whole swarm
## arriving on the same frame kills once.
func die() -> void:
	if is_dead:
		return
	is_dead = true
	_shake_intensity = 0.8
	# Lands with the shake and the overlay, on the frame of the kill. The
	# idempotence guard above is what keeps this to one sting per death.
	play_sfx(SFX_FAH)
	if you_died_label != null:
		you_died_label.visible = true
	# A prop still riding the carry spring would keep being steered by a corpse.
	drop_prop()


## Clears the death screen and bounces the round back to Preparation, with the
## maze left exactly as it was -- that is the whole point of the retry loop.
func _respawn() -> void:
	_clear_death()
	GameState.reset_round()


## Cleanup shared by _respawn() and the round_reset signal.
func _clear_death() -> void:
	is_dead = false
	_shake_intensity = 0.0
	# A retry is a fresh attempt: the boss is re-spawned at full health, so the
	# player has to be too or the second attempt starts already beaten.
	health = max_health
	_update_health_bar()
	# reset_round() has already cleared GameState.boss_fight, so this holsters
	# everything -- a retry starts unarmed like any other round.
	equip(_slot)
	# A reset ends any duel in progress -- GameState.reset_round() frees the boss
	# -- so the bar goes away with it. This is the path `_on_round_reset()` takes.
	_set_health_bar_visible(false)
	if camera != null:
		camera.h_offset = 0.0
		camera.v_offset = 0.0
	if you_died_label != null:
		you_died_label.visible = false


## Back to the title. Round state is reset first because `GameState` is an
## autoload and survives the scene change -- without this the menu would launch
## the next run still believing a boss fight was in progress.
func _return_to_menu() -> void:
	_in_victory = false
	GameState.boss_fight = false
	GameState.prologue_active = false
	GameState.phase = GameState.Phase.PREPARATION
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func _on_round_reset() -> void:
	_in_victory = false
	_clear_death()
	# A reset ends any duel in progress (GameState.reset_round() frees the boss),
	# so the boss track has to end with it -- otherwise a retry out of the fight
	# rebuilds the maze under battle music that no longer has a battle.
	play_tabletop_music()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# The settings slider scales the scene's authored sensitivity. Typed
		# explicitly so a missing GameSettings autoload reports one clear error
		# rather than also failing type inference here.
		var look: float = mouse_sensitivity * GameSettings.sensitivity
		# Yaw turns the whole body so the placeholder model faces where you look.
		rotate_y(-event.relative.x * look)
		# Pitch tilts only the head/camera, clamped like a real Source client.
		var limit := deg_to_rad(pitch_limit_deg)
		_pitch = clampf(_pitch - event.relative.y * look, -limit, limit)
		head.rotation.x = _pitch

	# The ending card outranks everything: Space goes back to the menu and nothing
	# else does anything at all.
	if _in_victory:
		if event.is_action_pressed("ui_accept"):
			get_viewport().set_input_as_handled()
			_return_to_menu()
		return

	# Space ends the curse blackout. Checked before everything else, because
	# while the screen is black this is the only input that means anything.
	if _in_curse_blackout:
		if event.is_action_pressed("ui_accept"):
			# Space is "I have read this, move on", so the curse narration goes with
			# the screen it belongs to. `scene 1.mp3` outlasts a quick reader, and
			# leaving it running would have the curse still being pronounced over the
			# bench -- and over the track play_tabletop_music() starts a line later.
			_stop_voice()
			_end_prologue()
			get_viewport().set_input_as_handled()
		return

	# Death outranks everything below. Checked BEFORE the phase gate: a reset
	# triggered elsewhere can flip the phase to PREPARATION on the same press, and
	# the retry keys would then fall through the early return and do nothing.
	# The `return` is what stops a corpse shooting, reloading or grabbing props.
	if is_dead:
		if event.is_action_pressed("lock_in") or event.is_action_pressed("restart_round"):
			_respawn()
			# Consumed so GameState does not act on the same press. `restart_round`
			# during ACTION is its own reset key, so without this one G would run
			# reset_round() twice and double-count the attempt.
			get_viewport().set_input_as_handled()
		return

	# Looking around stays live in every phase, but weapons and prop-carrying do
	# not exist while building: the click, the wheel and the reach are all on
	# loan to BuildMode until the layout is locked in.
	if GameState.is_preparation():
		return

	# Weapon slots: number keys select directly, the wheel cycles. Handled here
	# rather than in _physics_process so a quick tap can never be missed, and so
	# switching is dead while the settings menu has the tree paused.
	if event.is_action_pressed("interact"):
		# Hands full -> put it down; empty -> grab whatever prop is in reach.
		if _carried != null:
			drop_prop()
		else:
			pick_up_prop()
	elif _carried != null and event.is_action_pressed("fire"):
		# With a prop in hand the fire button throws it instead of shooting --
		# the weapons are holstered and never see this press.
		throw_prop()
	elif _carried != null:
		# Weapons are holstered while carrying, so selecting a slot now would
		# leave it hidden. Reaching for a weapon puts the prop down first.
		if (
			event.is_action_pressed("slot_1")
			or event.is_action_pressed("slot_2")
			or event.is_action_pressed("slot_next")
			or event.is_action_pressed("slot_prev")
		):
			drop_prop()
	elif event.is_action_pressed("slot_1"):
		equip(0)
	elif event.is_action_pressed("slot_2"):
		equip(1)
	elif event.is_action_pressed("slot_next"):
		equip(_slot + 1)
	elif event.is_action_pressed("slot_prev"):
		equip(_slot - 1)


func _physics_process(delta: float) -> void:
	# Off the bench. Checked before the death branch so the fall registers on the
	# frame it happens rather than a frame later, and gated on `not is_dead` so a
	# corpse that keeps sinking cannot re-trigger. die() is idempotent anyway, but
	# this keeps the intent readable.
	# Not during the prologue: the kitchen floor is 73 units BELOW the bench, so
	# the fall-death threshold would fire the moment the player spawns on it.
	# Written as a guard on the check rather than an early `return` from
	# _physics_process -- returning here would freeze the player mid-prologue.
	if not is_prologue and not is_dead and global_position.y < FALL_DEATH_Y:
		die()

	# Frozen while the curse subtitle is up, but still driven so gravity keeps
	# the body settled.
	if _in_curse_blackout or _in_victory:
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= gravity * delta
		move_and_slide()
		return

	if is_dead:
		# Frozen in place, but still driven: gravity and move_and_slide keep the
		# body settled on the bench instead of hanging wherever it was standing.
		velocity.x = 0.0
		velocity.z = 0.0
		if is_on_floor():
			velocity.y = 0.0
		else:
			velocity.y -= gravity * delta
		move_and_slide()
		return

	_update_crouch(delta)

	var grounded := is_on_floor()
	# Crouch outranks walk, so ducking while holding Shift stays crouch-speed.
	var speed := max_speed
	if _crouching:
		speed = crouch_speed
	elif Input.is_action_pressed("walk"):
		speed = walk_speed
	if is_prologue:
		# Overrides crouch and walk alike: the prologue is a single, deliberate
		# pace. Scaled to match the 74.77x body -- see the export's note.
		speed = prologue_speed * PROLOGUE_SCALE
	var wish_dir := _get_wish_direction()
	var wants_jump := (
		Input.is_action_pressed("jump")
		if auto_bhop
		else Input.is_action_just_pressed("jump")
	)

	if grounded:
		if wants_jump:
			# Bunny hop: launch, then air-accelerate on the same frame and
			# skip friction so horizontal momentum is preserved.
			velocity.y = jump_velocity
			if not _jumped:
				jump.play()
				_jumped = true
			_air_accelerate(wish_dir, speed, air_accel, delta)
		else:
			_apply_friction(delta)
			_ground_accelerate(wish_dir, speed, ground_accel, delta)
			velocity.y = 0.0
			_jumped = false
	else:
		if _was_grounded:
			# Fresh airborne stretch -- start a new Gain % measurement.
			_gain_actual = 0.0
			_gain_ideal = 0.0
		velocity.y -= gravity * delta
		_measure_air_gain(wish_dir, speed, delta)
		# Going airborne re-arms the jump SFX so the next landing hops with sound.
		_jumped = false

	_was_grounded = grounded
	# move_and_slide() slides velocity along whatever it hits, so the speed the
	# player was carrying INTO a prop is gone by the time the contacts can be
	# read. Keep it here for _push_bodies().
	var approach := velocity
	move_and_slide()
	# Both of these run after the move so they act on this frame's contacts and
	# this frame's camera position.
	_push_bodies(approach, delta)
	_update_carry(delta)


## Jitters the camera by shrinking amounts until the shake runs out.
##
## Driven from _process, not _physics_process: this is purely visual, and at a
## 60 Hz physics tick a shake sampled per physics frame reads as a judder rather
## than a rattle on a high-refresh display. Uses the camera's h/v offsets rather
## than its transform so it composes with the head's pitch instead of fighting
## the look controls for the same property.
func _update_camera_shake(delta: float) -> void:
	if camera == null:
		return
	if _shake_intensity <= 0.0:
		camera.h_offset = 0.0
		camera.v_offset = 0.0
		return
	camera.h_offset = randf_range(-1.0, 1.0) * _shake_intensity * 0.4
	camera.v_offset = randf_range(-1.0, 1.0) * _shake_intensity * 0.4
	# Decays over ~0.4 s from the 0.8 die() sets, so the hit lands hard and is
	# gone well before the player reaches for the retry key.
	_shake_intensity = maxf(_shake_intensity - delta * 2.0, 0.0)


## Refreshes the bottom-left stats readout each rendered frame. Velocity is the
## horizontal (XZ) speed in Source units -- that's the number bunny-hoppers
## watch, since vertical speed contributes nothing to strafe gain.
func _process(delta: float) -> void:
	_update_camera_shake(delta)
	_update_book_prompt()
	_update_prep_tutorial()
	_update_phase_label()
	var pos := global_position
	stats_label.text = (
		"Velocity: %.0f u/s\n"
		+ "Pos (X,Y,Z): %.1f, %.1f, %.1f\n"
		+ "Ang (P,Y,R): %.1f, %.1f, %.1f\n"
		+ "Gain: %.0f%%"
	) % [
		Vector2(velocity.x, velocity.z).length() * units_per_metre,
		pos.x, pos.y, pos.z,
		rad_to_deg(head.rotation.x),
		rad_to_deg(rotation.y),
		rad_to_deg(head.rotation.z),
		_gain_pct,
	]


## Swaps the player between builder and shooter.
##
## PREPARATION holsters everything: an empty pair of hands is the clearest
## signal that the click now moves furniture instead of firing. ACTION hands the
## previously selected weapon back.
func _on_phase_changed(new_phase: int) -> void:
	if new_phase == GameState.Phase.PREPARATION:
		if _carried != null:
			drop_prop()
		for weapon in weapons:
			if is_instance_valid(weapon):
				weapon.equipped = false
		# A reset is a retry, so put the player back where the attempt began.
		global_transform = _spawn_transform
		velocity = Vector3.ZERO
		_pitch = 0.0
		head.rotation.x = 0.0
	else:
		equip(_slot)


## Bottom-centre phase readout: which half of the loop is running and the key
## that leaves it.
func _update_phase_label() -> void:
	# Debug scaffolding, off by default. It reads as leftover developer text over
	# the game -- the phase and its keys belong in a designed HUD, not in a
	# two-line dump. Flip PhaseLabel/StatsLabel visible in Player.tscn to get them
	# back while working.
	if phase_label == null or not phase_label.visible:
		return
	if GameState.is_preparation():
		phase_label.text = (
			"PREPARATION  -  attempt %d\n"
			+ "LMB grab / place obstacle    WHEEL rotate    F lock in"
		) % GameState.attempt
	else:
		phase_label.text = "ACTION  -  attempt %d\nG restart" % GameState.attempt


## Puts exactly one weapon in the player's hands: the equipped one shows itself
## and reads fire input, the rest hide and go inert. The index wraps, so cycling
## with the wheel runs off either end back around.
func equip(slot: int) -> void:
	if weapons.is_empty():
		return
	_slot = wrapi(slot, 0, weapons.size())
	# **The stage decides the weapon, not the slot keys.** See
	# _weapon_slot_for_stage(): nothing during the prologue, the Stasis Cannon for
	# the build-and-survive round, the Staff of Quartz for the Archmage duel.
	#
	# Gating here rather than at each call site makes it the single place a weapon
	# can come out -- and because each weapon gates its own input handler on
	# `equipped`, holstering here also disables firing.
	var allowed := _weapon_slot_for_stage()
	for i in weapons.size():
		if is_instance_valid(weapons[i]):
			weapons[i].equipped = i == allowed


## Which weapon the current stage of the round allows, or -1 for none.
##
## The prologue is unarmed because the player is a full-size person walking a
## kitchen; the duel swaps to the staff because that is the curse-breaker. Every
## other stage -- PREPARATION, the coin round, ACTION -- is the Stasis Cannon,
## which is what the swarm was balanced around.
func _weapon_slot_for_stage() -> int:
	if is_prologue:
		return -1
	if GameState.boss_fight:
		return STAFF_SLOT
	return 0


## Shoves any physics prop the capsule slid against this frame. A CharacterBody3D
## carries no mass of its own, so without this the player just glides along
## rigid bodies as if they were walls. The impulse is horizontal-only (walking
## into a table slides it, it doesn't flip it) and scales with closing speed, so
## leaning on a prop nudges it and sprinting into it sends it skidding.
##
## `approach` is the velocity from BEFORE move_and_slide() -- afterwards it has
## been slid along the contact and no longer says how hard the player pushed.
func _push_bodies(approach: Vector3, delta: float) -> void:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var body := collision.get_collider()
		# The carried prop is steered by _update_carry(); shoving it as well
		# would fight that and make it buzz against the player.
		if not body is RigidBody3D or body == _carried:
			continue

		var push_dir := -collision.get_normal()
		push_dir.y = 0.0
		if push_dir.length_squared() < 0.001:
			continue
		push_dir = push_dir.normalized()

		# Only the part of the player's motion heading INTO the prop counts, so
		# sliding along a prop's edge barely disturbs it.
		var closing := approach.dot(push_dir)
		if closing <= 0.0:
			continue

		# Applied at the contact point (levelled to the prop's centre height) so
		# a corner hit spins the prop instead of sliding it flat.
		var arm := collision.get_position() - (body as RigidBody3D).global_position
		arm.y = 0.0
		(body as RigidBody3D).apply_impulse(push_dir * closing * push_force * delta, arm)


## Picks up the prop under the crosshair, if it's in range and carryable.
## Holsters the current weapon for as long as it's held -- you can't aim a
## pistol with a table in your arms.
func pick_up_prop() -> void:
	if _carried != null:
		return
	var query := PhysicsRayQueryParameters3D.create(
		camera.global_position,
		camera.global_position - camera.global_basis.z * carry_range
	)
	query.exclude = [get_rid()]
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return

	var prop := hit["collider"] as Prop
	if prop == null or not prop.carryable:
		return

	_carried = prop
	prop.carried_by = self
	# The prop rides right in front of the face; without an exception it would
	# grind against the capsule and shove the player around.
	add_collision_exception_with(prop)
	_stowed_slot = _slot
	for weapon in weapons:
		weapon.equipped = false


## Puts the carried prop down where it is, restoring its gravity, its collision
## with the player and the weapon that was holstered to pick it up.
func drop_prop() -> void:
	if _carried == null:
		return
	var prop := _carried
	_carried = null
	prop.carried_by = null
	remove_collision_exception_with(prop)
	equip(_stowed_slot)


## Throws the carried prop along the view direction. The impulse is scaled by
## the prop's mass so throw_speed really is the launch speed whatever it weighs.
func throw_prop() -> void:
	if _carried == null:
		return
	var prop := _carried
	var direction := -camera.global_basis.z
	drop_prop()
	# Inherit the player's own motion, so running throws go further.
	prop.linear_velocity = velocity
	prop.apply_impulse(direction * throw_speed * prop.mass)


## Steers the held prop toward a point in front of the camera by setting its
## velocity, rather than teleporting it. Driving it through the physics engine
## is what keeps a carried table from being pushed through walls -- it still
## collides with everything on the way.
func _update_carry(delta: float) -> void:
	if _carried == null:
		return
	if not is_instance_valid(_carried):
		_carried = null
		return

	var forward := -camera.global_basis.z
	# Pull the hold point in short of any wall ahead, so held props press
	# against geometry instead of trying to occupy it.
	var reach := carry_distance
	var query := PhysicsRayQueryParameters3D.create(
		camera.global_position, camera.global_position + forward * carry_distance
	)
	query.exclude = [get_rid(), _carried.get_rid()]
	var wall := get_world_3d().direct_space_state.intersect_ray(query)
	if not wall.is_empty():
		reach = maxf(camera.global_position.distance_to(wall["position"]) - 0.2, 0.5)

	var offset := (camera.global_position + forward * reach) - _carried.global_position
	if offset.length() > carry_break_distance:
		# Wedged behind something the spring can't pull it through -- let go
		# rather than dragging it through the level.
		drop_prop()
		return

	_carried.linear_velocity = (offset * carry_stiffness).limit_length(carry_max_speed)
	# Bleed off spin so a prop grabbed by one corner settles down while held.
	_carried.angular_velocity *= pow(_carried.carry_spin_damping, delta)


## Crouch handling: while the crouch action is held the capsule + camera duck
## down; releasing only stands the player up when a full-height capsule fits
## (so you can't stand up into a ceiling).
func _update_crouch(delta: float) -> void:
	if Input.is_action_pressed("crouch"):
		_crouching = true
	elif _crouching and _has_headroom():
		_crouching = false

	var target_height := crouch_height if _crouching else _stand_height
	target_height = maxf(target_height, _capsule.radius * 2.0)
	var target_eye := crouch_eye if _crouching else _stand_eye
	var step := crouch_transition_speed * delta

	# Resize the collision capsule, keeping its base planted at the feet (origin).
	_capsule.height = move_toward(_capsule.height, target_height, step)
	collision_shape.position.y = _capsule.height * 0.5

	# Match the visible bean to the collision capsule.
	_mesh_capsule.height = _capsule.height
	mesh.position.y = _capsule.height * 0.5

	# Ease the camera to the new eye level.
	head.position.y = move_toward(head.position.y, target_eye, step)


## True when a standing-height capsule fits at the player's current position
## without hitting geometry -- i.e. it's safe to stand up. The probe is lifted
## slightly so it clears the floor the player is resting on.
func _has_headroom() -> bool:
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _stand_hull
	params.transform = Transform3D(
		Basis.IDENTITY,
		global_position + Vector3(0.0, _stand_height * 0.5 + 0.1, 0.0)
	)
	params.exclude = [get_rid()]
	params.collision_mask = collision_mask
	return get_world_3d().direct_space_state.intersect_shape(params, 1).is_empty()


## World-space horizontal direction the player wants to move, from WASD taken
## relative to the body's current yaw.
func _get_wish_direction() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := global_transform.basis * Vector3(input.x, 0.0, input.y)
	dir.y = 0.0
	return dir.normalized() if dir.length() > 0.0 else Vector3.ZERO


## Ground friction (Source CGameMovement::Friction). Bleeds off horizontal
## speed each frame; below stop_speed it decays at a fixed rate for a crisp stop.
func _apply_friction(delta: float) -> void:
	var speed := Vector3(velocity.x, 0.0, velocity.z).length()
	if speed < 0.001:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var control := maxf(speed, stop_speed)
	var drop := control * friction * delta
	var new_speed := maxf(speed - drop, 0.0) / speed
	velocity.x *= new_speed
	velocity.z *= new_speed


## Ground acceleration (Source CGameMovement::Accelerate). Adds speed toward
## wish_dir up to wish_speed, gated so it never overshoots the target.
func _ground_accelerate(wish_dir: Vector3, wish_speed: float, accel: float, delta: float) -> void:
	var current_speed := velocity.dot(wish_dir)
	var add_speed := wish_speed - current_speed
	if add_speed <= 0.0:
		return
	var accel_speed := minf(accel * wish_speed * delta, add_speed)
	velocity.x += accel_speed * wish_dir.x
	velocity.z += accel_speed * wish_dir.z


## Air-accelerates while scoring the result. Gain % is the speed this stretch
## actually produced divided by the most a perfectly-aimed strafe could have
## produced -- the whole accel budget landing perpendicular to current velocity,
## which grows speed by sqrt(v^2 + budget^2) - v.
func _measure_air_gain(wish_dir: Vector3, wish_speed: float, delta: float) -> void:
	var before := Vector2(velocity.x, velocity.z).length()
	_air_accelerate(wish_dir, wish_speed, air_accel, delta)

	# Only score frames where the player actually asked to move -- Gain % rates
	# strafe quality, not whether a key was held.
	if wish_dir == Vector3.ZERO:
		return

	var after := Vector2(velocity.x, velocity.z).length()
	var budget := minf(air_accel * wish_speed * delta, air_cap)
	_gain_actual += after - before
	_gain_ideal += sqrt(before * before + budget * budget) - before
	if _gain_ideal > 0.0:
		_gain_pct = clampf(_gain_actual / _gain_ideal * 100.0, 0.0, 100.0)


## Air acceleration (Source CGameMovement::AirAccelerate). The TARGET speed is
## clamped to air_cap, but the acceleration step still scales with the full
## wish_speed -- so turning into your strafe while airborne gains speed.
func _air_accelerate(wish_dir: Vector3, wish_speed: float, accel: float, delta: float) -> void:
	var target_speed := minf(wish_speed, air_cap)
	var current_speed := velocity.dot(wish_dir)
	var add_speed := target_speed - current_speed
	if add_speed <= 0.0:
		return
	var accel_speed := minf(accel * wish_speed * delta, add_speed)
	velocity.x += accel_speed * wish_dir.x
	velocity.z += accel_speed * wish_dir.z
