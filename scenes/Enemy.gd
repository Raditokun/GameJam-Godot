extends CharacterBody3D
## Prototype swarm enemy: walks from one end of the bench to the other, and
## abandons that route to charge the player the moment it can actually see them.
##
## This is the "Order in Disorder" twist in miniature. The patrol leg stands in
## for the hidden rule the real enemies will follow (steer toward blue, turn
## right at walls); what matters here is the AGGRO BREAK on top of it -- a
## player who takes a badly exposed firing position turns their own carefully
## ordered maze back into chaos, because every enemy that catches sight of them
## stops respecting the maze at all.
##
## Aggro deliberately needs BOTH conditions:
##   - the player is inside DetectionArea (a proximity check), and
##   - SightRay reaches them unblocked (a real line-of-sight check).
## Standing behind the bowl is therefore safe even at point-blank range, which
## is the whole point -- clutter is cover.
##
## Obstacle handling comes in two layers, covered in NavBaker.gd: the navmesh is
## re-carved when clutter settles, and NavigationAgent3D avoidance steers around
## it in real time while it is still being dragged.

## Emitted when the enemy picks up or loses the player, for HUD and audio hooks.
signal aggro_changed(chasing: bool)

enum State {
	## Following the set route to the goal marker.
	PATROL,
	## Route abandoned; running the player down.
	CHASE,
}

## Separation below which the direction to the player stops being meaningful --
## normalising a near-zero vector makes the enemy spin on the spot. At this range
## it is already in contact anyway.
const MIN_CHARGE_OFFSET := 0.2

## Height below which this enemy counts as having fallen off the bench and frees
## itself. The tabletop is at y ~= 73.6 and the leftover ground geometry is at
## y = -0.5, so anything under this is in free fall to somewhere it can never
## walk back from. Matches PrepCamera's threshold for the props.
const DESPAWN_Y_THRESHOLD := 65.0

## Separation at which a chasing enemy is touching the player and kills them.
## Both capsules have radius 0.4, so they physically stop at ~0.8 apart and can
## never close further -- 1.15 fires reliably on contact with a little slack for
## the tilted bench, without reaching through a gap the player is safely behind.
const KILL_DISTANCE := 1.15

## How hard a feeler hit steers the enemy sideways, as a fraction of its speed.
## The deflection is added to the desired direction and renormalised, so this is
## a blend weight, not an absolute: 0.75 bends the path around a corner without
## ever overpowering the direction the agent actually wants to go.
const CORNER_SLIDE_STRENGTH := 0.75
## Seconds of going nowhere before unstuck recovery throws a lateral dodge.
const UNSTICK_STUCK_TIME := 0.6
## Minimum seconds between dodges. See _unstick() for why this exists instead of
## zeroing _stuck_time.
const UNSTICK_COOLDOWN := 0.4

## Seconds between line-of-sight checks. `has_line_of_sight()` fires a forced
## raycast up to `aggro_range` (250) long, and at a full wave that was one such
## cast per enemy per physics frame -- one of the largest per-enemy costs on the
## bench. 0.12 s is far below `aggro_memory` (2.0), so the aggro state cannot
## flicker from the staleness; the worst case is spotting the player ~7 frames
## late, which is invisible next to a 2-second memory.
const LOS_INTERVAL := 0.12
## Seconds of being impeded before the corner feelers are consulted at all. See
## _corner_slide() for what this costs in behaviour.
const FEELER_STUCK_THRESHOLD := 0.08

## Where the Rig_Medium animations live.
##
## `Skeleton_Minion.glb` ships the rig and the meshes but **no AnimationPlayer and
## no animations at all** -- KayKit keeps them in separate per-rig packs. Both
## packs animate `Rig_Medium/Skeleton3D` with the same 23 bones the character
## carries, so their tracks resolve against the model unchanged. Two packs are
## needed because the run and the idle live in different files.
const ANIM_PACK_MOVEMENT := "res://3DModels/KayKit_Skeletons_1.1_FREE/KayKit_Skeletons_1.1_FREE/Animations/gltf/Rig_Medium/Rig_Medium_MovementBasic.glb"
const ANIM_PACK_GENERAL := "res://3DModels/KayKit_Skeletons_1.1_FREE/KayKit_Skeletons_1.1_FREE/Animations/gltf/Rig_Medium/Rig_Medium_General.glb"

## Names as they actually appear in those packs. There is no plain "Idle" or
## "Run" -- the pack uses Idle_A/Idle_B and Running_A/Running_B.
const ANIM_RUN := "Running_A"
const ANIM_IDLE := "Idle_A"
## Squared horizontal speed above which the enemy counts as moving.
const ANIM_MOVING_SPEED_SQ := 0.05

## One AnimationLibrary shared by every enemy, built once on first use. The
## Animation resources inside are shared by reference, so 35 skeletons cost one
## copy between them rather than 35.
static var _shared_anim_library: AnimationLibrary = null

@export_group("Movement")
## Ground speed in units per second. The bench is ~220 units end to end.
@export var move_speed := 8.0
## Multiplies move_speed while chasing -- a charging enemy should read as
## faster than a patrolling one.
@export var chase_speed_scale := 1.35
## How quickly the body swings around to face where it is going, in 1/seconds.
@export var turn_speed := 5.0
@export var gravity := 20.0

@export_group("Debuffs")
## Speed multiplier a stasis hit leaves behind: 0.4 means 40% of normal speed.
## Used when a caller does not pass one of its own.
@export var default_slow_factor := 0.4
## Seconds a stasis hit lasts, when the caller does not pass its own.
@export var default_slow_duration := 5.0

@export_group("Patrol")
## Group holding the waypoints this enemy walks. Every Node3D in the group
## becomes a stop on the circuit, in tree order, and the route wraps around --
## the enemy never runs out of somewhere to be. Looked up by group rather than
## an exported node reference: exported node refs in a hand-edited .tscn
## silently resolve to null unless the [node] line carries a node_paths marker.
##
## With a single marker the enemy's own spawn point is added as the second stop,
## so one marker still produces a there-and-back loop instead of a dead end.
@export var goal_group := "enemy_goal"
## Used when no marker is in `goal_group`.
@export var goal_position := Vector3.ZERO
## How close, in metres, counts as reaching a waypoint and moving to the next.
@export var arrive_distance := 4.0
## Give up on a waypoint after this many seconds and move to the next one. A
## waypoint that ends up unreachable -- walled in by the player's clutter, say --
## would otherwise stall the patrol forever.
@export var waypoint_timeout := 20.0
## Grace period before a "path stops short" reading is trusted. The agent reports
## navigation finished for a frame or two after a new target is set, before the path is
## actually built, and acting on that would cycle waypoints instantly.
@export var unreachable_grace := 0.75
## Give up on a waypoint after this many seconds of trying to move but going nowhere.
## Covers the case the navigation state cannot see: a path that exists on the navmesh but
## runs through something the capsule physically cannot pass, which leaves the enemy
## grinding against a prop until waypoint_timeout expires.
@export var stuck_timeout := 1.5

@export_group("Aggro")
## Group identifying the player. Same reasoning as goal_group.
@export var player_group := "player"
## Fallback aggro range in metres, used only if DetectionArea has no sphere to
## read. Normally the range comes from that shape, so the radius you can see in
## the editor is the one the logic actually uses -- _ready() overwrites this with
## the sphere's 250.0, which is bench-wide (the table is ~220 units end to end).
@export var aggro_range := 250.0
## Height above the enemy's feet the sight ray fires from, in metres.
@export var eye_height := 1.5
## Height above the player's feet the sight ray aims at. Aiming at the chest
## rather than the origin stops the ray from grazing the tabletop.
@export var target_height := 0.9
## Seconds the enemy keeps chasing after losing sight of the player. Without
## this the state flickers every time the player clips an obstacle edge; with
## it, breaking line of sight buys a few seconds rather than instant safety.
@export var aggro_memory := 2.0
## Seconds between target updates while chasing. Re-pathing every frame to a
## moving target is wasted work; a short interval still tracks convincingly.
@export var chase_repath_interval := 0.2
## How close the agent must get to the player before navigation reports arrival,
## while chasing. It has to be small enough to let the capsule actually reach
## them -- the agent stops dead the moment it is inside this radius, so anything
## body-sized parks the enemy just out of contact range.
@export var chase_arrive_distance := 0.5
## The same tolerance while patrolling. Deliberately looser than the chase value:
## a waypoint is a place to head for, not a thing to touch, and demanding
## pinpoint arrival makes the enemy jitter on the spot fine-tuning its position.
@export var patrol_arrive_distance := 2.0
## Seconds between goal re-reads while patrolling, so a moved marker is picked up.
@export var repath_interval := 0.4

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var detection_area: Area3D = $DetectionArea
@onready var sight_ray: RayCast3D = $SightRay
## Angled whiskers at knee height. Between them they see the corner the agent is
## about to clip before the capsule reaches it, which is what corner-slide assist
## steers off. Fetched with get_node_or_null so an older Enemy scene without them
## degrades to "no assist" rather than crashing on load.
@onready var feeler_left: RayCast3D = get_node_or_null("FeelerLeft") as RayCast3D
@onready var feeler_right: RayCast3D = get_node_or_null("FeelerRight") as RayCast3D
## Drives the skeleton. The node is added by Enemy.tscn as a child of `Model`, so
## its default root_node of ".." resolves to the model root -- exactly the layout
## the animation packs were exported with, which is why their bone paths resolve.
@onready var anim_player: AnimationPlayer = get_node_or_null("Model/AnimationPlayer") as AnimationPlayer

## True only while the match is actually running. Mirrors GameState (the global
## game manager) which owns the real phase; kept as a plain flag here so the
## enemy can be driven standalone in tests. Everything in _physics_process is
## gated on it -- during PREPARATION the enemy neither moves nor looks.
var is_action_phase := false

var state: State = State.PATROL

## The player, once they are inside DetectionArea. Null means out of range, and
## the line-of-sight check is skipped entirely.
var _player: Node3D = null
var _since_repath := 0.0
var _seen_for := 0.0
## Whether the sightline was clear on THIS physics frame, cached by _update_aggro
## so nothing else has to fire a second raycast to ask. Currently written but not
## read: direct pursuit no longer gates on line of sight. Kept as the hook for a
## HUD "they can see you" tell, which is the mechanic this state belongs to.
var _sees_player := false
## The patrol circuit, rebuilt from `goal_group` as it is walked so a waypoint
## that gets moved is picked up.
var _route: Array[Vector3] = []
var _route_index := 0
## Seconds spent heading for the current waypoint, against `waypoint_timeout`.
var _waypoint_time := 0.0
## Seconds spent trying to move while going nowhere, against `stuck_timeout`.
var _stuck_time := 0.0
## Seconds of stasis left, and the speed multiplier it applies while it lasts.
## Kept separate from the timer so the factor a shot delivered survives for
## exactly its own duration rather than being blended with the last one.
var _slow_timer := 0.0
var _slow_factor := 1.0
## Seconds left before unstuck recovery may throw another dodge.
var _dodge_cooldown := 0.0
## Counts down to the next line-of-sight raycast. Seeded randomly per enemy so a
## wave that spawns together does not all cast on the same frame and produce a
## periodic spike -- the whole point is to spread the cost, not just reduce it.
var _los_timer := randf_range(0.0, LOS_INTERVAL)
var _spawn_transform := Transform3D.IDENTITY
# move_and_slide() must run exactly once per physics frame. With avoidance on,
# the move happens in the velocity_computed callback, and this guards against a
# stray callback landing in the same frame as a direct drive.
var _move_frame := -1


func _ready() -> void:
	# Difficulty tuning — EASY gives the enemy a slower pace.
	if GameSettings.difficulty == GameSettings.Difficulty.EASY:
		move_speed = 6.5
		chase_speed_scale = 1.2
	_spawn_transform = global_transform
	agent.velocity_computed.connect(_on_velocity_computed)
	agent.max_speed = move_speed
	detection_area.body_entered.connect(_on_body_entered)
	detection_area.body_exited.connect(_on_body_exited)
	# Take the range straight off the detection shape so there is exactly one
	# number to tune, and it is the one visible in the editor.
	for child in detection_area.get_children():
		var shape := child as CollisionShape3D
		if shape != null and shape.shape is SphereShape3D:
			aggro_range = (shape.shape as SphereShape3D).radius
			break
	sight_ray.add_exception(self)
	# The feelers start at knee height, inside the capsule's own radius -- without
	# the exception they report the enemy's own body as the corner ahead and it
	# steers in circles forever.
	for feeler in [feeler_left, feeler_right]:
		if feeler != null:
			feeler.add_exception(self)
	if anim_player != null and not anim_player.has_animation_library(""):
		anim_player.add_animation_library("", _shared_animations())
	GameState.phase_changed.connect(_on_phase_changed)
	# The navigation map is not built until the first physics sync, so asking
	# for a path in _ready() returns nothing.
	_apply_phase.call_deferred(GameState.phase)


func _physics_process(delta: float) -> void:
	# Off the bench and falling. Checked before anything else and in every phase:
	# a body down here can never path back onto the table, so it would otherwise
	# fall forever, counting against max_live_enemies and being drawn on the radar
	# from somewhere the player cannot reach.
	if global_position.y < DESPAWN_Y_THRESHOLD:
		queue_free()
		return

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	_slow_timer = maxf(_slow_timer - delta, 0.0)
	# Before the phase gate, so a skeleton standing in PREPARATION still idles
	# rather than freezing on frame 0 of whatever it last played.
	_update_animation()

	# Preparation: hold still and stay blind. Still driven (with zero velocity)
	# so gravity settles it onto the bench.
	if not is_action_phase:
		_drive(Vector3.ZERO, delta)
		return

	# Nothing below here is safe until the navigation map can answer queries. Asking
	# early does not return a poor answer, it raises an error -- and an error inside
	# _physics_process aborts the rest of the function, so the enemy would never reach
	# its move call and would stand still looking like it had crashed.
	if not _navigation_ready():
		_drive(Vector3.ZERO, delta)
		return

	_update_aggro(delta)
	_check_contact_kill()
	_advance_patrol(delta)
	_update_target(delta)

	var desired := Vector3.ZERO
	if not agent.is_navigation_finished():
		var next_point := agent.get_next_path_position()
		# An agent with no usable path can hand back a non-finite point; normalising
		# that produces NaN velocity and the body leaves the map for good.
		if next_point.is_finite():
			var to_next := next_point - global_position
			to_next.y = 0.0
			if to_next.length() > 0.001:
				desired = to_next.normalized() * _current_speed()

	# Direct pursuit. Overrides the path for effectively the whole chase -- see
	# _line_of_sight_fallback() for why bypassing the navmesh is the fix for
	# distant enemies freezing rather than a shortcut around pathfinding.
	desired = _line_of_sight_fallback(desired)

	# Corner-slide assist and unstuck recovery run last, so they steer whatever
	# the enemy actually decided to do -- following the path or charging.
	desired = _corner_slide(desired)
	desired = _unstick(desired, delta)

	if agent.avoidance_enabled:
		# Hand the wish to the avoidance simulation; it answers on
		# velocity_computed with a version that dodges its neighbours.
		agent.velocity = desired
	else:
		_drive(desired, delta)


## Builds the shared AnimationLibrary from the two Rig_Medium packs, once.
##
## The packs import as PackedScenes, not AnimationLibrary resources, so the only
## way to reach their animations is to instantiate one and take them off its
## AnimationPlayer. The temporary node is freed immediately; Animation is a
## refcounted Resource, so the animations outlive it.
static func _shared_animations() -> AnimationLibrary:
	if _shared_anim_library != null:
		return _shared_anim_library

	var library := AnimationLibrary.new()
	for path in [ANIM_PACK_MOVEMENT, ANIM_PACK_GENERAL]:
		var packed := load(path) as PackedScene
		if packed == null:
			push_warning("[Enemy] animation pack missing: %s" % path)
			continue
		var temp := packed.instantiate()
		var source := temp.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if source != null:
			for anim_name in source.get_animation_list():
				if not library.has_animation(anim_name):
					library.add_animation(anim_name, source.get_animation(anim_name))
		temp.free()

	# The packs import one-shot. Without this the skeleton runs for 0.8 s and
	# then freezes mid-stride, which reads as the animation being broken.
	for looping in [ANIM_RUN, ANIM_IDLE]:
		if library.has_animation(looping):
			library.get_animation(looping).loop_mode = Animation.LOOP_LINEAR

	_shared_anim_library = library
	return _shared_anim_library


## Picks the run or idle clip and matches playback speed to stasis.
##
## Uses HORIZONTAL speed, not `velocity.length_squared()`: velocity carries
## gravity, so a stationary enemy that is falling or settling would otherwise be
## judged to be running on the spot.
func _update_animation() -> void:
	if anim_player == null:
		return
	# A stasis-slowed skeleton should visibly move in slow motion, not mime a
	# full-speed run while sliding along at 40%.
	anim_player.speed_scale = _slow_factor if _slow_timer > 0.0 else 1.0

	var moving := Vector2(velocity.x, velocity.z).length_squared() > ANIM_MOVING_SPEED_SQ
	var wanted := ANIM_RUN if moving else ANIM_IDLE
	if anim_player.current_animation == wanted or not anim_player.has_animation(wanted):
		return
	anim_player.play(wanted)


## Kills the player if this enemy has physically reached them.
##
## Gated on CHASE: a patroller that happens to brush past on its way somewhere
## else has not caught anyone, and killing on proximity alone would make the
## hidden-rule routes lethal to stand near rather than lethal to be SEEN by --
## which is the opposite of the mechanic. Player.die() is idempotent, so a whole
## swarm arriving together still only kills once.
func _check_contact_kill() -> void:
	if state != State.CHASE or _player == null or not is_instance_valid(_player):
		return
	if global_position.distance_to(_player.global_position) >= KILL_DISTANCE:
		return
	if _player.has_method("die"):
		_player.die()


## Drives straight at the player, off-path, for effectively the whole chase.
##
## This is not a "last few metres" tweak any more -- it fires whenever a chasing
## enemy is further than `chase_arrive_distance` (0.5) from the player, which is
## almost always. **During CHASE the navmesh is therefore bypassed entirely**, and
## pathfinding only governs PATROL.
##
## That is deliberate, and it is the fix for enemies freezing at a distance. The
## props' carve outlines fragment the bench into ~27 disconnected navmesh regions
## (see §2e in CLAUDE.md), so for most of the table there is simply no route from
## an enemy to the player: the agent gets a path to the nearest reachable point,
## reports `is_navigation_finished()` while still far away, and stops. Charging
## directly is the only thing that crosses a fragmented mesh. What keeps it from
## walking face-first into the clutter is the steering that runs after this --
## `_corner_slide()` reads the feelers, and `_unstick()` catches the rest.
func _line_of_sight_fallback(desired: Vector3) -> Vector3:
	if state != State.CHASE or _player == null or not is_instance_valid(_player):
		return desired

	var dir := _player.global_position - global_position
	dir.y = 0.0
	var distance := dir.length()
	if not agent.is_navigation_finished() and distance <= chase_arrive_distance:
		return desired
	# Inside this the direction is numerically meaningless and normalising it just
	# makes the enemy spin; it is already in contact anyway.
	if distance <= MIN_CHARGE_OFFSET:
		return desired
	return dir.normalized() * _current_speed()


## Steers around a corner the agent is about to clip.
##
## Navmesh paths cut corners, and RVO only knows about other agents, so the
## capsule scrapes along prop edges it was routed past. The angled feelers catch
## the edge and bend the desired direction away from it.
##
## **The feelers are only consulted once the enemy is actually being impeded**
## (`_stuck_time` past `FEELER_STUCK_THRESHOLD`). That is a cost trade, and it
## does change behaviour: the assist used to fire on the frame a feeler touched
## an edge, which let it steer BEFORE the capsule reached the corner. It is now
## reactive -- the enemy grazes the prop first, and slides once the contact has
## cost it ground. Feelers are `enabled = false` in the scene and force-updated
## here, so a skipped frame really does skip two raycasts per enemy rather than
## just skipping a read of a cast that happened anyway.
func _corner_slide(desired: Vector3) -> Vector3:
	if desired.length_squared() <= 0.01 or not is_on_floor():
		return desired
	if _stuck_time <= FEELER_STUCK_THRESHOLD:
		return desired

	var left_hit := false
	var right_hit := false
	if feeler_left != null:
		feeler_left.force_raycast_update()
		left_hit = feeler_left.is_colliding()
	if feeler_right != null:
		feeler_right.force_raycast_update()
		right_hit = feeler_right.is_colliding()
	# Exactly one side blocked is a corner to slide along. Both blocked is a dead
	# end rather than a corner -- deflecting there only picks which wall to grind
	# against, so leave that to unstuck recovery. Neither blocked needs nothing.
	if left_hit == right_hit:
		return desired

	var speed := _current_speed()
	var lateral := global_transform.basis.x * speed * CORNER_SLIDE_STRENGTH
	# basis.x is the enemy's right, so a hit on the left pushes right and back.
	var steered := (desired + lateral) if left_hit else (desired - lateral)
	if steered.length() < 0.001:
		return desired
	return steered.normalized() * speed


## Last resort: throw the enemy sideways when it has been asking to move and
## going nowhere. Catches what the feelers cannot -- wedged between two props,
## jammed against a neighbour, or standing on a path that leads into a solid.
##
## **Deliberately does not zero `_stuck_time`,** using its own cooldown instead.
## `_advance_patrol()` gives up on a waypoint at `stuck_timeout` (1.5 s), and that
## is the only thing that rescues a route which is valid on the navmesh but
## impassable to the capsule. Resetting the shared counter every 0.6 s would cap
## it below 1.5 s forever, silently killing that give-up and stranding the enemy
## dodging in place at a waypoint it can never reach. Leaving the counter to keep
## climbing means a dodge that works clears it naturally (via `_drive`), and one
## that does not still escalates to abandoning the waypoint.
func _unstick(desired: Vector3, delta: float) -> Vector3:
	_dodge_cooldown = maxf(_dodge_cooldown - delta, 0.0)
	if _stuck_time <= UNSTICK_STUCK_TIME or _dodge_cooldown > 0.0:
		return desired

	_dodge_cooldown = UNSTICK_COOLDOWN
	# Whatever route it was on leads into the thing it is wedged against, so the
	# same path would walk it straight back in. Force a fresh one.
	_since_repath = 999.0
	var side := 1.0 if randf() > 0.5 else -1.0
	return global_transform.basis.x * side * _current_speed()


## True once the navigation map exists and has completed a synchronisation, so path
## queries are legal. The iteration id is the only reliable signal -- a map can report
## itself valid a frame or two before it can actually answer.
func _navigation_ready() -> bool:
	if agent == null:
		return false
	var map := agent.get_navigation_map()
	return map.is_valid() and NavigationServer3D.map_get_iteration_id(map) > 0


## True once the enemy has reached its current target. Safe to call at any time: an
## unsynchronised map reports "not finished" rather than erroring.
func has_arrived() -> bool:
	if not _navigation_ready():
		return false
	return agent.is_navigation_finished()


func is_chasing() -> bool:
	return state == State.CHASE


## True when the player is both in range and actually visible. This is the check
## the whole aggro mechanic turns on, so it is public for tests and for any
## future "the enemy is onto you" HUD warning.
func has_line_of_sight() -> bool:
	if _player == null or not is_instance_valid(_player):
		return false
	# Explicit range check rather than trusting Area3D membership alone. Area
	# enter/exit is resolved once per physics frame, so a player who leaves (or
	# teleports) is still "inside" for a frame -- and since the ray is aimed at
	# them wherever they are, that one frame is enough to aggro across the whole
	# bench. The radius is the gate; this makes it the gate at all times.
	if global_position.distance_to(_player.global_position) > aggro_range:
		return false

	var from := global_position + Vector3.UP * eye_height
	var to := _player.global_position + Vector3.UP * target_height
	sight_ray.global_position = from
	# target_position is local and this body yaws as it walks, so the world
	# direction has to be converted rather than assigned straight in.
	sight_ray.target_position = sight_ray.to_local(to)
	sight_ray.force_raycast_update()

	if not sight_ray.is_colliding():
		# Nothing at all between here and the player's chest.
		return true
	# Anything else in the way -- the bowl, a wall -- breaks the sightline.
	return sight_ray.get_collider() == _player


## Aggro state machine. Sight starts the chase immediately; losing it only ends
## the chase once aggro_memory has run out.
func _update_aggro(delta: float) -> void:
	# The raycast runs at most every LOS_INTERVAL; every other frame reuses the
	# cached answer. See the const for why the staleness is harmless.
	_los_timer -= delta
	if _los_timer <= 0.0:
		_sees_player = has_line_of_sight()
		_los_timer = LOS_INTERVAL

	if _sees_player:
		_seen_for = aggro_memory
	else:
		_seen_for = maxf(_seen_for - delta, 0.0)

	var should_chase := _seen_for > 0.0
	if should_chase == (state == State.CHASE):
		return

	state = State.CHASE if should_chase else State.PATROL
	_apply_arrive_tuning()
	# Force an immediate re-path so the switch is visible on the next frame
	# rather than up to repath_interval later.
	_since_repath = 999.0
	aggro_changed.emit(state == State.CHASE)


## Keeps the agent's arrival tolerance in step with the state. Applied on every
## state change rather than left at the scene's authored value, because the two
## states want opposite things from it: a chaser has to be allowed all the way in
## to make contact, while a patroller wants slack so it does not fidget on a
## waypoint. Also re-applied on phase changes, which set the state directly.
func _apply_arrive_tuning() -> void:
	if agent == null:
		return
	agent.target_desired_distance = (
		chase_arrive_distance if state == State.CHASE else patrol_arrive_distance
	)


## Points the navigation agent at whatever the current state is after.
func _update_target(delta: float) -> void:
	_since_repath += delta
	var interval := chase_repath_interval if state == State.CHASE else repath_interval
	if _since_repath < interval:
		return
	_since_repath = 0.0

	if state == State.CHASE and _player != null and is_instance_valid(_player):
		agent.target_position = _player.global_position
	else:
		# Rebuilt as it walks, so a waypoint the designer drags around is
		# followed without restarting the round.
		_build_route()
		agent.target_position = _current_waypoint()


## Steps to the next waypoint once this one is reached, wrapping at the end so
## the patrol runs forever instead of stopping dead on the last marker.
func _advance_patrol(delta: float) -> void:
	if state != State.PATROL:
		return
	if _route.is_empty():
		_build_route()
		if _route.is_empty():
			return

	_waypoint_time += delta
	var here := global_position
	var waypoint := _current_waypoint()
	# Compare on the horizontal plane only: the waypoint markers sit on the
	# tabletop while the capsule's origin rides at its feet, and a stray metre
	# of height difference should not stop it counting as arrived.
	var flat := Vector2(here.x - waypoint.x, here.z - waypoint.z).length()
	# A waypoint walled off by the player's clutter leaves the agent holding a path that
	# stops short: navigation reports "finished" while the enemy is still far away, so it
	# stands motionless until waypoint_timeout expires. On the bench that reads exactly
	# like the enemy walking into an invisible wall and freezing for 20 seconds. Detect
	# the stranded case and move on immediately instead.
	var stranded := (
		_waypoint_time > unreachable_grace
		and flat > arrive_distance
		and (agent.is_navigation_finished() or _stuck_time > stuck_timeout)
	)
	if not stranded and flat > arrive_distance and _waypoint_time < waypoint_timeout:
		return
	_stuck_time = 0.0

	_route_index = (_route_index + 1) % _route.size()
	_waypoint_time = 0.0
	agent.target_position = _current_waypoint()
	# Skip the repath wait so the next leg starts on the very next frame and the
	# enemy never visibly pauses at a corner.
	_since_repath = 999.0


## Collects the patrol circuit. Every Node3D in `goal_group` is a stop; a single
## marker gets the spawn point added so the route still loops.
func _build_route() -> void:
	var route: Array[Vector3] = []
	for marker in get_tree().get_nodes_in_group(goal_group):
		var node := marker as Node3D
		if node != null:
			route.append(node.global_position)
	if route.is_empty() and goal_position != Vector3.ZERO:
		route.append(goal_position)
	if route.size() == 1:
		route.append(_spawn_transform.origin)
	_route = route
	if _route.is_empty():
		_route_index = 0
	else:
		_route_index = _route_index % _route.size()


func _current_waypoint() -> Vector3:
	if _route.is_empty():
		return global_position
	return _route[_route_index]


func _current_speed() -> float:
	var base := move_speed * (chase_speed_scale if state == State.CHASE else 1.0)
	if _slow_timer > 0.0:
		base *= _slow_factor
	return base


## Puts this enemy in stasis: `factor` of its normal speed for `duration`
## seconds. Called by the Stasis Cannon through has_method(), so nothing on the
## weapon side needs to know what an Enemy is.
##
## A fresh hit replaces the current stasis outright rather than stacking or
## multiplying -- two cannon shots should not compound into a near-total freeze,
## and the second shot re-arming the full duration is the behaviour a player
## expects from re-applying a debuff.
func apply_slow(factor: float = default_slow_factor, duration: float = default_slow_duration) -> void:
	_slow_factor = factor
	_slow_timer = duration


## Whether stasis is currently in effect, and how much of it is left. Public for
## a future HUD tell or a shader tint on the capsule.
func is_slowed() -> bool:
	return _slow_timer > 0.0


func slow_remaining() -> float:
	return _slow_timer


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group(player_group):
		_player = body


func _on_body_exited(body: Node3D) -> void:
	if body == _player:
		_player = null
		# Out of range counts as out of sight; aggro_memory still runs down
		# from here rather than dropping instantly.


func _on_phase_changed(new_phase: int) -> void:
	_apply_phase(new_phase)


## ACTION switches the enemy on. PREPARATION switches it off and puts it back
## where it started, so every retry of the maze is run from the same setup.
func _apply_phase(new_phase: int) -> void:
	is_action_phase = new_phase == GameState.Phase.ACTION
	if is_action_phase:
		_build_route()
		agent.target_position = _current_waypoint()
		_apply_arrive_tuning()
		_waypoint_time = 0.0
		_stuck_time = 0.0
		return

	if state == State.CHASE:
		aggro_changed.emit(false)
	state = State.PATROL
	_apply_arrive_tuning()
	_seen_for = 0.0
	_sees_player = false
	_dodge_cooldown = 0.0
	_since_repath = 999.0
	_route_index = 0
	_waypoint_time = 0.0
	velocity = Vector3.ZERO
	global_transform = _spawn_transform


func _on_velocity_computed(safe_velocity: Vector3) -> void:
	_drive(safe_velocity, get_physics_process_delta_time())


## Applies a horizontal velocity and moves. Vertical motion is left alone so
## gravity keeps the capsule pinned to the tabletop. Guarded so it can only run
## once per physics frame however it was reached.
func _drive(horizontal: Vector3, delta: float) -> void:
	var frame := Engine.get_physics_frames()
	if _move_frame == frame:
		return
	_move_frame = frame

	velocity.x = horizontal.x
	velocity.z = horizontal.z
	var before := global_position
	move_and_slide()
	# Track "wanted to move but didn't". move_and_slide() slides along contacts, so a
	# capsule wedged in a corner still reports a non-zero velocity while covering no
	# ground -- comparing actual displacement is the only reliable stuck signal.
	var wanted := horizontal.length() * delta
	if wanted > 0.001 and global_position.distance_to(before) < wanted * 0.25:
		_stuck_time += delta
	else:
		_stuck_time = 0.0
	if horizontal.length_squared() > 0.01:
		# -Z is the capsule's forward, matching the player's convention.
		var target_yaw := atan2(-horizontal.x, -horizontal.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(turn_speed * delta, 0.0, 1.0))
