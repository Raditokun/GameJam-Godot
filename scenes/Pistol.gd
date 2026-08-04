extends Node3D
## Slot 1 -- the Stasis Cannon. One slow, heavy hitscan shot on a 25-second
## cooldown that does not kill what it hits: it SLOWS it.
##
## The cooldown is the design, not a balance knob. At 25 seconds the shot is a
## resource rather than a weapon -- it cannot be used to fight a swarm, only to
## buy time against the one enemy about to reach the player, or to hold a choke
## point open long enough to get through it. Fire it at the wrong moment and
## there is nothing to fall back on for the next 25 seconds, which is what makes
## the maze the actual answer to the swarm and the cannon only the escape hatch.
##
## The slow is delivered by duck-typing: anything with an `apply_slow(factor,
## duration)` method takes it. Nothing is hard-wired to the enemy type, so a
## future boss or destructible can opt in by growing the method.

@export_group("Shooting")
## The camera-mounted ray used for hitscan. Points at Camera3D/RayCast3D.
@export var ray: RayCast3D
## Seconds before the cannon can fire again. The whole point of the weapon.
@export var cooldown_time := 25.0
## Damage handed to a target's take_damage() per shot. Nothing on the bench has
## a health system yet, so this is currently inert on enemies.
@export var damage := 15.0
## Impulse in newton-seconds a shot delivers to a physics prop. Small on
## purpose -- shots should rock a table, not launch it.
@export var impact_force := 12.0

@export_group("Stasis")
## Speed multiplier applied to whatever is hit: 0.4 leaves 40% of its speed.
@export var slow_factor := 0.4
## Seconds the slow lasts on the target.
@export var slow_duration := 5.0

@export_group("HUD")
## Bottom-right charge meter. Points at the player's HUD/GunBar. Fills from
## empty back to full as the cannon recharges.
@export var cooldown_bar: ProgressBar

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

@onready var muzzle: Marker3D = $Muzzle

## True while this weapon is the one in the player's hands. Holstered weapons
## hide themselves, ignore fire input, and take their charge meter with them --
## a cannon cooldown means nothing while the sword is out.
var equipped := true:
	set(value):
		equipped = value
		visible = value
		if cooldown_bar != null:
			cooldown_bar.visible = value

## Seconds left before the cannon can fire again. Zero means charged.
var _cooldown_timer := 0.0


func _ready() -> void:
	# Difficulty tuning — EASY gives a shorter cooldown and a longer slow.
	if GameSettings.difficulty == GameSettings.Difficulty.EASY:
		cooldown_time = 18.0
		slow_duration = 6.5
	if cooldown_bar == null:
		return
	# Set the range here rather than trusting the scene: the fill maths below
	# reports a percentage, and a bar left on some other range would show a
	# charge state that has nothing to do with the real cooldown.
	cooldown_bar.min_value = 0.0
	cooldown_bar.max_value = 100.0
	cooldown_bar.value = 100.0
	cooldown_bar.visible = equipped


func _physics_process(delta: float) -> void:
	# Ticks whether or not the weapon is equipped: the cannon recharges in the
	# holster, so switching to the sword is not a way to dodge the cooldown.
	_cooldown_timer = maxf(_cooldown_timer - delta, 0.0)

	if cooldown_bar == null:
		return
	cooldown_bar.visible = equipped
	# 0 right after firing, 100 when charged -- a meter filling back up, which
	# reads as "ready?" far better than a countdown draining away.
	cooldown_bar.value = (1.0 - (_cooldown_timer / maxf(cooldown_time, 0.001))) * 100.0


func _unhandled_input(event: InputEvent) -> void:
	if not equipped:
		return
	if event.is_action_pressed("fire") and _cooldown_timer == 0.0:
		_fire()


## Hitscan shot: resolves what the camera ray hits and draws a tracer from the
## muzzle to that point, or to the ray's full length when nothing is hit.
func _fire() -> void:
	if ray == null:
		return
	_cooldown_timer = cooldown_time

	# Resolve the ray right now rather than trusting the last physics tick.
	ray.force_raycast_update()
	var hit_point := (
		ray.get_collision_point()
		if ray.is_colliding()
		else ray.to_global(ray.target_position)
	)
	if ray.is_colliding():
		_apply_impact(ray.get_collider(), hit_point)
	_spawn_tracer(muzzle.global_position, hit_point)


## Hands the slow, damage and a shot's worth of momentum to whatever was hit.
## All three are routed through has_method() so shooting plain level geometry
## stays a no-op, and so nothing here depends on the enemy's concrete type.
func _apply_impact(collider: Object, point: Vector3) -> void:
	if collider == null:
		return
	if collider.has_method("apply_slow"):
		collider.apply_slow(slow_factor, slow_duration)
	if collider.has_method("take_damage"):
		collider.take_damage(damage)
	if collider.has_method("apply_hit"):
		collider.apply_hit(point, -ray.global_basis.z, impact_force)


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
