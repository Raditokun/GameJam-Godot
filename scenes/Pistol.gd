extends Node3D
## Low-poly placeholder pistol: hitscan firing with fading white tracers, plus a
## manual reload that dips the weapon and blocks shooting while it plays.
##
## Ammo is infinite while `infinite_ammo` is on -- the counters render but never
## drop, and reload is purely the animation and the fire lockout it imposes.
## Turning that flag off switches on real consumption with no other changes.

@export_group("Shooting")
## The camera-mounted ray used for hitscan. Points at Camera3D/RayCast3D.
@export var ray: RayCast3D
## Minimum seconds between shots.
@export var fire_cooldown := 0.15

@export_group("Tracer")
## Seconds the tracer stays up while it fades out.
@export var tracer_lifetime := 0.25
## Thickness of the beam in metres. This needs real width: the beam runs from
## the muzzle to the crosshair, so you view it nearly end-on and a thin one
## collapses to a sub-pixel line.
@export var tracer_thickness := 0.06
@export var tracer_color := Color(1.0, 1.0, 1.0, 1.0)
## Draw the beam over geometry so walls and the weapon can never hide it.
@export var tracer_draw_on_top := true

@export_group("Ammo")
## Bullets per magazine, as shown in the HUD.
@export var magazine_size := 15
## Magazines carried.
@export var magazine_count := 7
## While true the counters never decrease.
@export var infinite_ammo := true
## Bottom-right ammo readout. Points at the player's HUD/AmmoLabel.
@export var ammo_label: Label

@export_group("Reload")
## Total seconds the reload takes; shooting is blocked for the whole duration.
@export var reload_time := 1.0
## How far the weapon dips down during the reload, in metres.
@export var reload_dip := 0.15
## How far the weapon tilts down during the reload, in degrees.
@export var reload_tilt_deg := 25.0

@onready var muzzle: Marker3D = $Muzzle

## True while this weapon is the one in the player's hands. Holstered weapons
## hide themselves, ignore fire/reload input, and take their ammo readout with
## them -- a pistol magazine count means nothing while the sword is out.
var equipped := true:
	set(value):
		equipped = value
		visible = value
		if ammo_label != null:
			ammo_label.visible = value

var _cooldown := 0.0
var _reloading := false
var _rest_position := Vector3.ZERO
var _rest_rotation := Vector3.ZERO
var _bullets := 0
var _mags := 0


func _ready() -> void:
	# Remember the authored pose so the reload animation can return to it.
	_rest_position = position
	_rest_rotation = rotation
	_bullets = magazine_size
	_mags = magazine_count
	_update_ammo_label()


func _process(delta: float) -> void:
	if not equipped:
		return
	_cooldown = maxf(_cooldown - delta, 0.0)

	if Input.is_action_just_pressed("reload"):
		_reload()
	if Input.is_action_just_pressed("fire"):
		_fire()


## Hitscan shot: resolves what the camera ray hits and draws a tracer from the
## muzzle to that point, or to the ray's full length when nothing is hit.
func _fire() -> void:
	if _reloading or _cooldown > 0.0 or ray == null:
		return
	if not infinite_ammo and _bullets <= 0:
		return
	_cooldown = fire_cooldown

	if not infinite_ammo:
		_bullets -= 1
		_update_ammo_label()

	# Resolve the ray right now rather than trusting the last physics tick.
	ray.force_raycast_update()
	var hit_point := (
		ray.get_collision_point()
		if ray.is_colliding()
		else ray.to_global(ray.target_position)
	)
	_spawn_tracer(muzzle.global_position, hit_point)


## Builds a thick unshaded beam spanning from -> to, fades its alpha out and
## frees it. Parented to the running scene rather than the weapon so it stays
## put in the world instead of riding along with the camera.
func _spawn_tracer(from: Vector3, to: Vector3) -> void:
	var beam := to - from
	var length := beam.length()
	if length < 0.001:
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = tracer_color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = tracer_draw_on_top

	var box := BoxMesh.new()
	box.size = Vector3(tracer_thickness, tracer_thickness, length)
	box.material = material

	var tracer := MeshInstance3D.new()
	tracer.mesh = box
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(tracer)

	# Centre the box on the beam, then aim its -Z down the beam so the box spans
	# exactly muzzle -> impact.
	tracer.global_position = (from + to) * 0.5
	var up := Vector3.UP
	if absf(beam.normalized().dot(Vector3.UP)) > 0.999:
		up = Vector3.RIGHT  # firing straight up/down needs a different up vector
	tracer.look_at(to, up)

	var tween := tracer.create_tween()
	tween.tween_property(material, "albedo_color:a", 0.0, tracer_lifetime)
	tween.tween_callback(tracer.queue_free)


## Dips the weapon down and brings it back over reload_time, blocking fire for
## the duration.
func _reload() -> void:
	if _reloading:
		return
	_reloading = true

	var dip_time := reload_time * 0.35
	var hold_time := reload_time - dip_time * 2.0
	var down_position := _rest_position + Vector3(0.0, -reload_dip, 0.0)
	var down_rotation := _rest_rotation + Vector3(deg_to_rad(-reload_tilt_deg), 0.0, 0.0)

	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "position", down_position, dip_time)
	tween.parallel().tween_property(self, "rotation", down_rotation, dip_time)
	tween.tween_interval(hold_time)
	tween.tween_property(self, "position", _rest_position, dip_time)
	tween.parallel().tween_property(self, "rotation", _rest_rotation, dip_time)
	tween.tween_callback(_on_reload_finished)


func _on_reload_finished() -> void:
	_reloading = false
	if not infinite_ammo:
		_mags = maxi(_mags - 1, 0)
		_bullets = magazine_size
		_update_ammo_label()


## Refreshes the bottom-right readout: bullets in the current magazine over the
## magazine size, then how many magazines are carried.
func _update_ammo_label() -> void:
	if ammo_label == null:
		return
	ammo_label.text = "%d / %d\nMAGS %d" % [_bullets, magazine_size, _mags]
