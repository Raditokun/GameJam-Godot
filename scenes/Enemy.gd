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

@export_group("Movement")
## Ground speed in units per second. The bench is ~220 units end to end.
@export var move_speed := 8.0
## Multiplies move_speed while chasing -- a charging enemy should read as
## faster than a patrolling one.
@export var chase_speed_scale := 1.35
## How quickly the body swings around to face where it is going, in 1/seconds.
@export var turn_speed := 5.0
@export var gravity := 20.0

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
## the editor is the one the logic actually uses.
@export var aggro_range := 45.0
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
## Seconds between goal re-reads while patrolling, so a moved marker is picked up.
@export var repath_interval := 0.4

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var detection_area: Area3D = $DetectionArea
@onready var sight_ray: RayCast3D = $SightRay

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
## The patrol circuit, rebuilt from `goal_group` as it is walked so a waypoint
## that gets moved is picked up.
var _route: Array[Vector3] = []
var _route_index := 0
## Seconds spent heading for the current waypoint, against `waypoint_timeout`.
var _waypoint_time := 0.0
## Seconds spent trying to move while going nowhere, against `stuck_timeout`.
var _stuck_time := 0.0
var _spawn_transform := Transform3D.IDENTITY
# move_and_slide() must run exactly once per physics frame. With avoidance on,
# the move happens in the velocity_computed callback, and this guards against a
# stray callback landing in the same frame as a direct drive.
var _move_frame := -1


func _ready() -> void:
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
	GameState.phase_changed.connect(_on_phase_changed)
	# The navigation map is not built until the first physics sync, so asking
	# for a path in _ready() returns nothing.
	_apply_phase.call_deferred(GameState.phase)


func _physics_process(delta: float) -> void:
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

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

	if agent.avoidance_enabled:
		# Hand the wish to the avoidance simulation; it answers on
		# velocity_computed with a version that dodges its neighbours.
		agent.velocity = desired
	else:
		_drive(desired, delta)


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
	var visible_now := has_line_of_sight()
	if visible_now:
		_seen_for = aggro_memory
	else:
		_seen_for = maxf(_seen_for - delta, 0.0)

	var should_chase := _seen_for > 0.0
	if should_chase == (state == State.CHASE):
		return

	state = State.CHASE if should_chase else State.PATROL
	# Force an immediate re-path so the switch is visible on the next frame
	# rather than up to repath_interval later.
	_since_repath = 999.0
	aggro_changed.emit(state == State.CHASE)


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
	return move_speed * (chase_speed_scale if state == State.CHASE else 1.0)


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
		_waypoint_time = 0.0
		_stuck_time = 0.0
		return

	if state == State.CHASE:
		aggro_changed.emit(false)
	state = State.PATROL
	_seen_for = 0.0
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
