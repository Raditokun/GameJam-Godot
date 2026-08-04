extends Node3D
## Slot 2 -- the Staff of Quartz, the boss-fight weapon.
##
## Two attacks, both PROJECTILES rather than hitscan. That is the point: the boss
## is a duel at range, so shots having travel time is what makes leading a moving
## target and dodging its return fire into a fight rather than a click contest.
##
##   LMB  -- a fast, cheap bolt. 5 damage, short cooldown. The chip damage.
##   RMB  -- a heavy, slower orb. 25 damage on a 3 s cooldown. The commitment.
##
## Damage is delivered through `has_method("take_damage")`, so the staff has no
## idea what a boss is and shooting scenery stays a no-op.

## Spell Effects (Free) visuals. Each is a self-contained particle rig with its
## own script driving the delayed sub-emitters -- several of their GPUParticles3D
## start `emitting = false` and are switched on by that script, so the scenes are
## instantiated whole rather than harvested for parts.
const ATTACK_PROJECTILE := preload("res://3DModels/Spell Effects (Free)/spell_effects/attack_projectile.tscn")
const ATTACK_IMPACT := preload("res://3DModels/Spell Effects (Free)/spell_effects/attack_impact.tscn")
const SPELL_2_ORB := preload("res://3DModels/Spell Effects (Free)/spell_effects/spell_2_orb.tscn")
const SPELL_2_IMPACT := preload("res://3DModels/Spell Effects (Free)/spell_effects/spell_2_impact.tscn")

## Seconds an impact burst stays alive before freeing itself. Comfortably longer
## than the longest emitter in either burst (attack_impact's Embers run 2.0 s, so
## the tail is cut -- but a burst left standing is a leak, and 0.8 s covers the
## flare, glow, sparks and the bulk of the fire).
const IMPACT_LIFETIME := 0.8

@export_group("Primary (LMB)")
## 15, not the 5 this shipped with: at 5 the 500 HP boss took 100 clean hits,
## which is a slog rather than a fight. 15 makes it ~34.
@export var bolt_damage := 15.0
@export var bolt_speed := 70.0
## Seconds between primary shots. Not zero -- without a floor this is a firehose
## and the heavy attack has no reason to exist.
@export var bolt_cooldown := 0.18
@export var bolt_radius := 0.09
@export var bolt_color := Color(0.55, 0.85, 1.0)

@export_group("Secondary (RMB)")
## 40 against the primary's 15. The heavy is worth its 3 s cooldown only if it
## beats the ~16 damage the primary would land in that window.
@export var heavy_damage := 40.0
@export var heavy_speed := 42.0
@export var heavy_cooldown := 3.0
@export var heavy_radius := 0.24
@export var heavy_color := Color(0.85, 0.45, 1.0)

@export_group("Projectiles")
## Seconds a projectile lives before giving up and freeing itself. Without this
## every missed shot flies forever and leaks.
@export var projectile_lifetime := 4.0
## How far in front of the muzzle a projectile spawns, so it clears the player's
## own capsule instead of colliding with it on frame one.
@export var muzzle_offset := 0.6

@export_group("HUD")
## Charge meter for the heavy attack. Points at HUD/StaffBar.
@export var cooldown_bar: ProgressBar

@onready var muzzle: Marker3D = get_node_or_null("Muzzle") as Marker3D

## True while this weapon is in the player's hands. Mirrors Pistol.gd so the
## slot switching in Player.gd works the same for both.
var equipped := true:
	set(value):
		equipped = value
		visible = value
		if cooldown_bar != null:
			cooldown_bar.visible = value

var _bolt_timer := 0.0
var _heavy_timer := 0.0


func _ready() -> void:
	if cooldown_bar == null:
		return
	cooldown_bar.min_value = 0.0
	cooldown_bar.max_value = 100.0
	cooldown_bar.value = 100.0
	cooldown_bar.visible = equipped


func _physics_process(delta: float) -> void:
	# Both cooldowns tick whether or not the staff is in hand, so swapping weapons
	# is not a way to skip the heavy attack's 3 seconds.
	_bolt_timer = maxf(_bolt_timer - delta, 0.0)
	_heavy_timer = maxf(_heavy_timer - delta, 0.0)

	if cooldown_bar == null:
		return
	cooldown_bar.visible = equipped
	# Shows the HEAVY charge -- the primary's 0.18 s is too short to read.
	cooldown_bar.value = (1.0 - (_heavy_timer / maxf(heavy_cooldown, 0.001))) * 100.0


func _unhandled_input(event: InputEvent) -> void:
	if not equipped:
		return
	if event.is_action_pressed("fire") and _bolt_timer == 0.0:
		_bolt_timer = bolt_cooldown
		_spawn_projectile(
			bolt_damage, bolt_speed, bolt_radius, bolt_color,
			ATTACK_PROJECTILE, ATTACK_IMPACT
		)
	elif event.is_action_pressed("fire_secondary") and _heavy_timer == 0.0:
		_heavy_timer = heavy_cooldown
		_spawn_projectile(
			heavy_damage, heavy_speed, heavy_radius, heavy_color,
			SPELL_2_ORB, SPELL_2_IMPACT
		)


## Launches a bolt along the camera's aim.
##
## Fired from the CAMERA's forward, not the staff's own -Z: the staff is posed off
## to one side of the screen, so its local axis points somewhere other than the
## crosshair and shots would drift.
func _spawn_projectile(
	damage: float, speed: float, radius: float, color: Color,
	visual: PackedScene, impact: PackedScene
) -> void:
	var camera := _aim_camera()
	if camera == null:
		return
	var direction := -camera.global_basis.z.normalized()
	var origin: Vector3 = (
		muzzle.global_position if muzzle != null else camera.global_position
	) + direction * muzzle_offset

	var shooter := _shooter()
	# Parented to the running scene, not the weapon, so it keeps flying straight
	# instead of riding the camera as the player turns. `current_scene` is null
	# for a scene hosted by hand rather than loaded by the SceneTree, so fall back
	# to whatever the shooter is parented to.
	var host: Node = get_tree().current_scene
	if host == null and shooter != null:
		host = shooter.get_parent()
	if host == null:
		return

	var bolt := Bolt.new()
	bolt.configure(damage, direction * speed, radius, color, projectile_lifetime, shooter)
	bolt.visual_scene = visual
	bolt.impact_scene = impact
	host.add_child(bolt)
	bolt.global_position = origin


func _aim_camera() -> Camera3D:
	var node := get_parent()
	while node != null:
		if node is Camera3D:
			return node as Camera3D
		node = node.get_parent()
	return get_viewport().get_camera_3d()


## The body the shot came from, so the projectile can ignore it.
func _shooter() -> Node3D:
	var node := get_parent()
	while node != null:
		if node is CharacterBody3D:
			return node as Node3D
		node = node.get_parent()
	return null


## A single magic projectile.
##
## An inner class rather than its own scene: it is a sphere with a velocity and a
## damage number, and it is only ever created from here. Area3D rather than a
## body so it passes through without shoving anything -- it should deal damage,
## not knock the boss around.
class Bolt:
	extends Area3D

	var damage := 0.0
	var velocity := Vector3.ZERO
	var life := 4.0
	## Particle rig carried along as the trail/aura. Set before add_child.
	var visual_scene: PackedScene = null
	## Burst left behind at the point of impact.
	var impact_scene: PackedScene = null
	var _shooter: Node3D = null

	func configure(
		p_damage: float, p_velocity: Vector3, radius: float, color: Color,
		lifetime: float, shooter: Node3D
	) -> void:
		damage = p_damage
		velocity = p_velocity
		life = lifetime
		_shooter = shooter

		# Layer 0 so nothing ever tests against the projectile; mask 1 so it sees
		# the world. It only needs to detect, never to be detected.
		collision_layer = 0
		collision_mask = 1
		monitoring = true

		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = radius
		shape.shape = sphere
		shape.name = "CollisionShape3D"
		add_child(shape)

		var glow := OmniLight3D.new()
		glow.light_color = color
		glow.omni_range = radius * 30.0
		glow.light_energy = 2.0
		glow.name = "Glow"
		add_child(glow)

	func _ready() -> void:
		body_entered.connect(_on_body_entered)
		if visual_scene == null:
			# No particle rig supplied -- fall back to a plain emissive sphere so
			# the shot is still visible rather than an invisible hitbox.
			_add_fallback_sphere()
			return
		var fx := visual_scene.instantiate()
		fx.name = "FX"
		add_child(fx)
		# attack_projectile.tscn is itself a CharacterBody3D with a collision
		# shape. It is layer 0 / mask 24 and this project uses layer 1, so it is
		# inert here and needs no neutering -- but silence it anyway, because a
		# decorative child has no business in the broadphase at all.
		for node in _descendants(fx):
			var body := node as PhysicsBody3D
			if body != null:
				body.collision_layer = 0
				body.collision_mask = 0

	func _add_fallback_sphere() -> void:
		var mesh_instance := MeshInstance3D.new()
		var sphere_mesh := SphereMesh.new()
		var r: float = 0.15
		sphere_mesh.radius = r
		sphere_mesh.height = r * 2.0
		var material := StandardMaterial3D.new()
		material.emission_enabled = true
		material.emission_energy_multiplier = 3.0
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sphere_mesh.material = material
		mesh_instance.mesh = sphere_mesh
		mesh_instance.name = "Mesh"
		add_child(mesh_instance)

	func _descendants(root: Node) -> Array[Node]:
		var found: Array[Node] = [root]
		for c in root.get_children():
			found.append_array(_descendants(c))
		return found

	func _physics_process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		global_position += velocity * delta

	func _on_body_entered(body: Node3D) -> void:
		# Never hit the player who fired it -- the muzzle sits inside their own
		# capsule's reach for the first frame or two.
		if body == _shooter or is_queued_for_deletion():
			return
		if body.has_method("take_damage"):
			body.take_damage(damage)
		_spawn_impact()
		queue_free()

	## Leaves the burst behind at the point of contact.
	##
	## Parented to the SCENE, not to this bolt -- the bolt frees itself on the
	## same frame, and a burst parented to it would be destroyed before drawing a
	## single particle.
	func _spawn_impact() -> void:
		if impact_scene == null:
			return
		var tree := get_tree()
		if tree == null:
			return
		var host: Node = tree.current_scene
		if host == null:
			host = get_parent()
		if host == null:
			return
		var burst := impact_scene.instantiate() as Node3D
		host.add_child(burst)
		burst.global_position = global_position
		# The rigs do not clean up after themselves, so give each burst a fuse.
		tree.create_timer(IMPACT_LIFETIME).timeout.connect(burst.queue_free)
