extends Node3D
## Melee katana: a short camera-aligned hitscan swing with a procedural slash.
##
## Shaped like Pistol.gd on purpose -- the weapon owns its own input handling,
## cooldown and animation, and the Player only decides which weapon is equipped.
##
## The reach ray is the CAMERA's, not the sword's. This node sits rotated ~84
## degrees in the player scene so its own -Z axis points off to the player's
## right; a locally-aimed raycast would swing at thin air. Sharing the camera
## ray also keeps melee aim identical to where the crosshair points.
##
## There is no baked animation yet, so the slash is a Tween over the pose the
## node was authored with, captured in _ready().

## Emitted on a connecting swing, for hit markers / sounds / damage numbers.
signal hit_target(collider: Object, point: Vector3)

@export_group("Melee")
## The camera-mounted ray, shared with the pistol. Points at Camera3D/RayCast3D.
@export var ray: RayCast3D
## How far the swing reaches, in metres.
@export var melee_range := 2.75
## Minimum seconds between swings.
@export var attack_cooldown := 0.5
## Passed to a victim's take_damage() when one is hit.
@export var damage := 40.0
## Impulse in newton-seconds delivered to a physics prop that's hit. Enough to
## send a table sliding, since a swing is a whole-body wallop, but the prop
## clamps how much leverage it turns into spin (see Prop.hit_torque_arm).
@export var knockback := 60.0

@export_group("Slash Animation")
## Seconds for the swing itself -- fast, so it reads as a snap.
@export var slash_time := 0.1
## Seconds for the recovery back to the idle pose.
@export var return_time := 0.2
## Euler offset from the idle pose at the peak of the swing, in degrees. Tuned
## by rendering candidate peaks: the blade has to travel a long way left and
## down, because rotating near the screen edge alone reads as a twist in place
## rather than a slash across the view.
@export var slash_rotation_deg := Vector3(-40.0, 85.0, -70.0)
## Positional offset from the idle pose at the peak of the swing, in metres.
@export var slash_offset := Vector3(-0.70, -0.28, 0.02)

## True while this weapon is the one in the player's hands. Holstered weapons
## hide themselves and ignore fire input.
var equipped := true:
	set(value):
		equipped = value
		visible = value

var _cooldown := 0.0
var _rest_position := Vector3.ZERO
var _rest_rotation := Vector3.ZERO
var _tween: Tween


func _ready() -> void:
	# Whatever pose the scene was authored with is "idle"; the slash returns here.
	_rest_position = position
	_rest_rotation = rotation


func _process(delta: float) -> void:
	if not equipped:
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	if Input.is_action_just_pressed("fire"):
		attack()


## Swings if off cooldown. The hit is resolved on the frame the swing starts
## rather than mid-animation, so the sword feels responsive.
func attack() -> void:
	if _cooldown > 0.0:
		return
	_cooldown = attack_cooldown
	_play_slash()
	_resolve_hit()


## Camera-ray hitscan clipped to melee_range. The shared ray reaches 100 m for
## the pistol, so distance has to be checked explicitly or the sword would
## "hit" whatever is across the map.
func _resolve_hit() -> void:
	if ray == null:
		return
	ray.force_raycast_update()
	if not ray.is_colliding():
		return
	var point := ray.get_collision_point()
	if ray.global_position.distance_to(point) > melee_range:
		return
	var collider := ray.get_collider()
	if collider != null and collider.has_method("take_damage"):
		collider.take_damage(damage)
	# Physics props also take the swing's momentum, along the aim direction so
	# the knock follows the crosshair rather than the blade's odd local axes.
	if collider != null and collider.has_method("apply_hit"):
		collider.apply_hit(point, -ray.global_basis.z, knockback)
	hit_target.emit(collider, point)


## Snap out along the swing arc, then ease back to idle. Any in-flight slash is
## killed first so rapid switching can't leave the sword stranded off-pose.
func _play_slash() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()

	var swing_rotation := _rest_rotation + slash_rotation_deg * (PI / 180.0)
	var swing_position := _rest_position + slash_offset

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "rotation", swing_rotation, slash_time)
	_tween.parallel().tween_property(self, "position", swing_position, slash_time)
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(self, "rotation", _rest_rotation, return_time)
	_tween.parallel().tween_property(self, "position", _rest_position, return_time)
