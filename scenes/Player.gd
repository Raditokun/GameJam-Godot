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
# Weapon slots in order: slot 1, slot 2. Reached with $ rather than exported
# NodePaths because both live inside this scene; node exports only resolve when
# the .tscn carries a node_paths= marker, which is easy to lose by hand.
@onready var weapons: Array[Node3D] = [
	$Head/Camera3D/Pistol,
	$Head/Camera3D/Sword,
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
	# Start on slot 1. This also drives the initial visibility of both weapons,
	# overriding whatever `visible` the scene was saved with.
	equip(0)


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

	# Weapon slots: number keys select directly, the wheel cycles. Handled here
	# rather than in _physics_process so a quick tap can never be missed, and so
	# switching is dead while the settings menu has the tree paused.
	if event.is_action_pressed("slot_1"):
		equip(0)
	elif event.is_action_pressed("slot_2"):
		equip(1)
	elif event.is_action_pressed("slot_next"):
		equip(_slot + 1)
	elif event.is_action_pressed("slot_prev"):
		equip(_slot - 1)


func _physics_process(delta: float) -> void:
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
	move_and_slide()


## Refreshes the bottom-left stats readout each rendered frame. Velocity is the
## horizontal (XZ) speed in Source units -- that's the number bunny-hoppers
## watch, since vertical speed contributes nothing to strafe gain.
func _process(_delta: float) -> void:
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


## Puts exactly one weapon in the player's hands: the equipped one shows itself
## and reads fire input, the rest hide and go inert. The index wraps, so cycling
## with the wheel runs off either end back around.
func equip(slot: int) -> void:
	if weapons.is_empty():
		return
	_slot = wrapi(slot, 0, weapons.size())
	for i in weapons.size():
		weapons[i].equipped = i == _slot


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
