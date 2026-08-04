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

## True from the moment an enemy reaches the player until they retry. Gates
## movement and every input except the two retry keys.
var is_dead := false
## Current camera shake amplitude, decaying to zero. Set by die().
var _shake_intensity := 0.0


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
	_apply_difficulty_lighting()


## Applies the HARD-mode pitch-dark environment. On HARD the DirectionalLight
## is disabled, background mode switches to pitch-black color, and ambient light
## is set to dark color mode, leaving only the player's SpotLight3D ("Flashlight").
## On EASY/MEDIUM, daylight and procedural sky are restored and flashlight is off.
func _apply_difficulty_lighting() -> void:
	var flashlight := get_node_or_null("Head/Camera3D/Flashlight") as Light3D
	var dir_light := get_tree().current_scene.find_child("DirectionalLight3D", true, false) as DirectionalLight3D
	var world_env := get_tree().current_scene.find_child("WorldEnvironment", true, false) as WorldEnvironment

	if GameSettings.difficulty == GameSettings.Difficulty.HARD:
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
	else:
		if dir_light != null:
			dir_light.visible = true
			dir_light.light_energy = 1.0
		if world_env != null and world_env.environment != null:
			var env := world_env.environment
			env.background_mode = Environment.BG_SKY
			env.ambient_light_source = Environment.AMBIENT_SOURCE_BG
		if flashlight != null:
			flashlight.visible = false


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
func begin_boss_fight(boss: Node) -> void:
	equip(STAFF_SLOT)
	health = max_health
	_update_health_bar()
	# The duel is the only thing that spends health, so this is where the bar
	# earns its place on screen.
	_set_health_bar_visible(true)
	if boss_health_bar == null:
		return
	boss_health_bar.visible = true
	if boss == null or not is_instance_valid(boss):
		return
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


func _on_boss_died() -> void:
	if boss_health_bar != null:
		boss_health_bar.visible = false


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
	# A reset ends any duel in progress -- GameState.reset_round() frees the boss
	# -- so the bar goes away with it. This is the path `_on_round_reset()` takes.
	_set_health_bar_visible(false)
	if camera != null:
		camera.h_offset = 0.0
		camera.v_offset = 0.0
	if you_died_label != null:
		you_died_label.visible = false


func _on_round_reset() -> void:
	_clear_death()


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
	if not is_dead and global_position.y < FALL_DEATH_Y:
		die()

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
	for i in weapons.size():
		if is_instance_valid(weapons[i]):
			weapons[i].equipped = (i == _slot)


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
