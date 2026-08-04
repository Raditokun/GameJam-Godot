extends CharacterBody3D
## Archmage Malakor -- the boss.
##
## A duel, not a swarm. Where the minions are a crowd-control problem the maze
## solves, the Archmage is a single target with 500 HP that fights back at range,
## so the fight is about dodging and landing shots rather than about layout.
##
## Two attacks on independent clocks:
##   Spell   -- a slow travelling orb. 75 on a direct hit, 35 to anything inside
##              `splash_radius` of the impact. Dodgeable if you are moving.
##   Leap    -- every `leap_interval` it jumps to wherever the player is standing
##              and lands. Inside `crush_radius` of the landing point that is an
##              instant kill, so it forces the player to keep moving.
##
## Everything reaches the player through `has_method()`, so the boss depends on
## no concrete player type.

signal health_changed(current: float, maximum: float)
signal died

@export_group("Health")
@export var max_health := 500.0

@export_group("Movement")
## Walks toward the player between attacks so it cannot be kited forever.
@export var move_speed := 5.5
@export var turn_speed := 4.0
@export var gravity := 20.0
## Stops closing once this near, so it does not simply body-block the player.
@export var preferred_distance := 12.0

@export_group("Spell attack")
@export var spell_interval := 2.6
@export var spell_damage := 75.0
@export var splash_damage := 35.0
@export var splash_radius := 2.5
@export var spell_speed := 22.0
## How hard the player's camera shakes when a spell is cast.
@export var cast_shake := 0.25

@export_group("Leap attack")
@export var leap_interval := 9.0
## Instant kill if the player is inside this of the landing point.
@export var crush_radius := 1.5
## Vertical launch speed. With gravity 20 this gives roughly a 1.4 s arc.
@export var leap_rise := 14.0
@export var land_shake := 0.7

@export_group("Groups")
@export var player_group := "player"

## Height below which the boss counts as having fallen off the bench.
const DESPAWN_Y_THRESHOLD := 65.0
## Rig_Medium animation packs, shared with the minions.
const ANIM_PACK_MOVEMENT := "res://3DModels/KayKit_Skeletons_1.1_FREE/KayKit_Skeletons_1.1_FREE/Animations/gltf/Rig_Medium/Rig_Medium_MovementBasic.glb"
const ANIM_PACK_GENERAL := "res://3DModels/KayKit_Skeletons_1.1_FREE/KayKit_Skeletons_1.1_FREE/Animations/gltf/Rig_Medium/Rig_Medium_General.glb"
const ANIM_RUN := "Running_A"
const ANIM_IDLE := "Idle_A"
const ANIM_MOVING_SPEED_SQ := 0.05
## The travelling orb and its impact burst, from Spell Effects (Free). Both carry
## their own scripts driving delayed sub-emitters, so they are instantiated whole.
const SPELL_2_ORB := preload("res://3DModels/Spell Effects (Free)/spell_effects/spell_2_orb.tscn")
const SPELL_2_IMPACT := preload("res://3DModels/Spell Effects (Free)/spell_effects/spell_2_impact.tscn")
## Seconds an impact burst lives before freeing itself.
const IMPACT_LIFETIME := 0.8
## The Archmage's colour. Tints the orb away from the asset's authored blue-white
## so his fire reads as his and not as the player's staff.
const SPELL_TINT := Color(1.0, 0.32, 0.12)

static var _shared_anim_library: AnimationLibrary = null

@onready var anim_player: AnimationPlayer = get_node_or_null("Model/AnimationPlayer") as AnimationPlayer

var health := 500.0
var _player: Node3D = null
var _spell_timer := 0.0
var _leap_timer := 0.0
var _airborne := false
var _leap_target := Vector3.ZERO


func _ready() -> void:
	health = max_health
	_spell_timer = spell_interval
	_leap_timer = leap_interval
	add_to_group("boss")
	if anim_player != null and not anim_player.has_animation_library(""):
		anim_player.add_animation_library("", _shared_animations())
	# Emitted deferred so a health bar connected right after spawn still receives
	# the opening value.
	_announce_health.call_deferred()


func _announce_health() -> void:
	health_changed.emit(health, max_health)


func _physics_process(delta: float) -> void:
	if global_position.y < DESPAWN_Y_THRESHOLD:
		queue_free()
		return

	if is_on_floor():
		if _airborne:
			_airborne = false
			_on_landed()
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	_player = _resolve_player()
	_update_animation()

	if _player == null:
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return

	if _airborne:
		# Mid-leap: keep the launch velocity, steer nothing. The arc is committed
		# the moment it leaves the ground, which is what makes the leap dodgeable.
		move_and_slide()
		return

	_spell_timer = maxf(_spell_timer - delta, 0.0)
	_leap_timer = maxf(_leap_timer - delta, 0.0)
	if _spell_timer == 0.0:
		_spell_timer = spell_interval
		_cast_spell()
	if _leap_timer == 0.0:
		_leap_timer = leap_interval
		_begin_leap()
		return

	_approach(delta)
	move_and_slide()


## Walks toward the player, stopping at `preferred_distance` so the fight stays
## at range instead of turning into a shoving match.
func _approach(delta: float) -> void:
	var to_player := _player.global_position - global_position
	to_player.y = 0.0
	var distance := to_player.length()
	var wish := Vector3.ZERO
	if distance > preferred_distance and distance > 0.001:
		wish = to_player.normalized() * move_speed
	velocity.x = wish.x
	velocity.z = wish.z

	# Face the player whether moving or not -- a caster that fires sideways reads
	# as broken.
	if distance > 0.001:
		var target_yaw := atan2(-to_player.x, -to_player.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(turn_speed * delta, 0.0, 1.0))


func _cast_spell() -> void:
	if _player == null:
		return
	var origin := global_position + Vector3.UP * 3.0
	var target := _player.global_position + Vector3.UP * 0.9
	var direction := (target - origin).normalized()

	# `current_scene` is null for a scene hosted by hand rather than loaded by the
	# SceneTree, so fall back to the boss's own parent.
	var host: Node = get_tree().current_scene
	if host == null:
		host = get_parent()
	if host == null:
		return

	var orb := SpellOrb.new()
	orb.configure(
		spell_damage, splash_damage, splash_radius,
		direction * spell_speed, player_group, self
	)
	host.add_child(orb)
	orb.global_position = origin
	_shake_player(cast_shake)


func _begin_leap() -> void:
	if _player == null:
		return
	_leap_target = _player.global_position
	var offset := _leap_target - global_position
	offset.y = 0.0
	# Ballistic arc: airtime is 2 * rise / gravity, so the horizontal speed that
	# lands on the target falls straight out of it.
	var airtime := 2.0 * leap_rise / maxf(gravity, 0.001)
	velocity = Vector3(offset.x / airtime, leap_rise, offset.z / airtime)
	_airborne = true
	move_and_slide()


func _on_landed() -> void:
	_shake_player(land_shake)
	if _player == null or not is_instance_valid(_player):
		return
	var flat := _player.global_position - global_position
	flat.y = 0.0
	if flat.length() <= crush_radius and _player.has_method("die"):
		_player.die()


func take_damage(amount: float) -> void:
	if health <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	if health <= 0.0:
		died.emit()
		queue_free()


func health_fraction() -> float:
	return health / maxf(max_health, 0.001)


func _shake_player(amount: float) -> void:
	if _player != null and _player.has_method("shake"):
		_player.shake(amount)


func _resolve_player() -> Node3D:
	if _player != null and is_instance_valid(_player) and _player.is_inside_tree():
		return _player
	for node in get_tree().get_nodes_in_group(player_group):
		var candidate := node as Node3D
		if candidate != null:
			return candidate
	return null


func _update_animation() -> void:
	if anim_player == null:
		return
	var moving := Vector2(velocity.x, velocity.z).length_squared() > ANIM_MOVING_SPEED_SQ
	var wanted := ANIM_RUN if moving else ANIM_IDLE
	if anim_player.current_animation == wanted or not anim_player.has_animation(wanted):
		return
	anim_player.play(wanted)


## Same two-pack merge the minions use -- see Enemy.gd for why this is necessary
## (the character glb ships no animations, and run and idle live in different
## files). Kept separate rather than shared so the boss can diverge later.
static func _shared_animations() -> AnimationLibrary:
	if _shared_anim_library != null:
		return _shared_anim_library
	var library := AnimationLibrary.new()
	for path in [ANIM_PACK_MOVEMENT, ANIM_PACK_GENERAL]:
		var packed := load(path) as PackedScene
		if packed == null:
			continue
		var temp := packed.instantiate()
		var source := temp.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if source != null:
			for anim_name in source.get_animation_list():
				if not library.has_animation(anim_name):
					library.add_animation(anim_name, source.get_animation(anim_name))
		temp.free()
	for looping in [ANIM_RUN, ANIM_IDLE]:
		if library.has_animation(looping):
			library.get_animation(looping).loop_mode = Animation.LOOP_LINEAR
	_shared_anim_library = library
	return _shared_anim_library


## The Archmage's travelling spell.
##
## Splash is resolved against the PLAYER GROUP at the impact point rather than
## with a second physics query: the only thing splash is meant to hurt is the
## player, and a group lookup cannot be fooled by whatever prop absorbed the hit.
class SpellOrb:
	extends Area3D

	var direct_damage := 75.0
	var splash_damage := 35.0
	var splash_radius := 2.5
	var velocity := Vector3.ZERO
	var life := 6.0
	var player_group := "player"
	var _caster: Node3D = null

	func configure(
		p_direct: float, p_splash: float, p_radius: float,
		p_velocity: Vector3, p_group: String, caster: Node3D
	) -> void:
		direct_damage = p_direct
		splash_damage = p_splash
		splash_radius = p_radius
		velocity = p_velocity
		player_group = p_group
		_caster = caster

		collision_layer = 0
		collision_mask = 1
		monitoring = true

		var shape := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = 0.45
		shape.shape = sphere
		shape.name = "CollisionShape3D"
		add_child(shape)

		var glow := OmniLight3D.new()
		glow.light_color = SPELL_TINT
		glow.light_energy = 3.0
		glow.omni_range = 8.0
		glow.name = "Glow"
		add_child(glow)

	func _ready() -> void:
		body_entered.connect(_on_body_entered)
		var fx := SPELL_2_ORB.instantiate()
		fx.name = "FX"
		add_child(fx)
		tint(fx, SPELL_TINT)

	## Recolours a particle rig toward `color`.
	##
	## **The process material MUST be duplicated first.** It is a shared Resource
	## loaded once per scene file, so writing the uniform in place would turn every
	## spell_2_orb in the game -- including the player's heavy blast -- crimson.
	##
	## Only reaches emitters exposing an `initial_color` uniform (Glow, Sparks,
	## Flare). The `Fire` layer is driven by gradient textures with no colour
	## uniform, so it keeps its authored look; the tint plus the crimson light is
	## what carries the read.
	static func tint(root: Node, color: Color) -> void:
		for node in _all_nodes(root):
			var particles := node as GPUParticles3D
			if particles == null:
				continue
			var material := particles.process_material as ShaderMaterial
			if material == null:
				continue
			var copy := material.duplicate() as ShaderMaterial
			copy.set_shader_parameter("initial_color", color)
			particles.process_material = copy

	static func _all_nodes(root: Node) -> Array[Node]:
		var found: Array[Node] = [root]
		for c in root.get_children():
			found.append_array(_all_nodes(c))
		return found

	func _physics_process(delta: float) -> void:
		life -= delta
		if life <= 0.0:
			queue_free()
			return
		global_position += velocity * delta

	func _on_body_entered(body: Node3D) -> void:
		if body == _caster or is_queued_for_deletion():
			return
		var direct := body.is_in_group(player_group)
		if direct and body.has_method("take_damage"):
			body.take_damage(direct_damage)
		elif not direct:
			_splash()
		_spawn_impact()
		queue_free()

	## Burst at the point of impact -- which is also the splash centre, so the
	## player can see how close the near-miss was.
	##
	## Parented to the scene rather than to this orb, which frees itself on the
	## same frame and would take the burst with it.
	func _spawn_impact() -> void:
		var tree := get_tree()
		if tree == null:
			return
		var host: Node = tree.current_scene
		if host == null:
			host = get_parent()
		if host == null:
			return
		var burst := SPELL_2_IMPACT.instantiate() as Node3D
		host.add_child(burst)
		burst.global_position = global_position
		tint(burst, SPELL_TINT)
		tree.create_timer(IMPACT_LIFETIME).timeout.connect(burst.queue_free)

	## Anything in the player group within `splash_radius` of the impact takes the
	## lesser hit. Near-misses still hurt, which is what stops the player from
	## simply standing behind a crate.
	func _splash() -> void:
		for node in get_tree().get_nodes_in_group(player_group):
			var target := node as Node3D
			if target == null or not target.has_method("take_damage"):
				continue
			if target.global_position.distance_to(global_position) <= splash_radius:
				target.take_damage(splash_damage)
