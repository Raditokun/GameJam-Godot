extends Node3D
## Time-based wave spawner: floods the bench with enemies from procedurally generated
## points around the edge of the play surface.
##
## Waves escalate on a clock -- wave 1 is `first_wave_size` enemies the moment ACTION
## starts, and every `wave_interval` seconds another wave arrives with
## `enemies_per_wave` more than the last. Everything is driven off `GameState`, so the
## spawner never needs a node path to the round logic.
##
## Spawn points are built once from the bounds of the play surface rather than hand
## placed, then each one is snapped onto the navigation mesh and thrown away if it does
## not land on walkable floor. That check is not optional on this bench: the clutter
## covers well over half the table, so a naive perimeter ring puts most of its points
## inside a crate or in a sealed pocket the enemy could never walk out of.

## Emitted when a wave begins, with the wave number and how many enemies it brought.
signal wave_started(wave: int, count: int)
## Emitted after the board is cleared, with how many enemies were removed.
signal enemies_cleared(count: int)

@export_group("Enemies")
## Scene instanced for every spawn. Must be the Enemy scene (CharacterBody3D + Enemy.gd).
@export var enemy_scene: PackedScene
## Group every live enemy joins, so a reset can find them without node paths.
@export var enemy_group := "enemies"
## Group identifying the player, for the safe-zone distance check.
@export var player_group := "player"

@export_group("Play Area")
## The node whose bounds define the play surface. Defaults to the navmesh bake surface,
## which is exactly the tabletop -- NOT `Floor`, which is leftover ground geometry ~74
## units below the bench. A plain NodePath rather than a typed node export on purpose:
## typed node exports silently resolve to null unless the .tscn also carries a
## `node_paths=PackedStringArray(...)` marker.
@export var area_path: NodePath = ^"../Navigation/NavSurface"
## Fallback used when `area_path` resolves to nothing.
@export var fallback_area_path: NodePath = ^"../Floor"
## How far inside the edge the ring sits, in metres. Enemies spawned exactly on the rim
## of the table tend to clip the lip and fall off.
@export var perimeter_inset := 8.0
## Distance between candidate points along the ring.
@export var perimeter_spacing := 6.0
## A candidate is discarded when the nearest navmesh position is further than this from
## it, which means it landed inside a prop or off the walkable area entirely.
@export var navmesh_tolerance := 2.5

@export_group("Waves")
## Enemies in wave 1.
@export var first_wave_size := 5
## Added to the wave size on every subsequent wave.
@export var enemies_per_wave := 1
## Seconds between waves.
@export var wave_interval := 45.0
## Hard ceiling on live enemies, so a long round cannot melt the frame budget.
@export var max_live_enemies := 35

@export_group("Safe Zone")
## A spawn point closer than this to the player is rejected and another is picked.
@export var min_player_distance := 10.0
## How many times to re-roll before giving up and using the furthest point available.
@export var max_spawn_attempts := 24

var _wave := 0
var _points: PackedVector3Array = PackedVector3Array()
var _timer: Timer
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	# Difficulty tuning — EASY gets a gentler swarm.
	if GameSettings.difficulty == GameSettings.Difficulty.EASY:
		first_wave_size = 3
		max_live_enemies = 25
		wave_interval = 55.0

	_timer = Timer.new()
	_timer.name = "WaveTimer"
	_timer.one_shot = false
	_timer.wait_time = maxf(wave_interval, 1.0)
	_timer.timeout.connect(_on_wave_timer)
	add_child(_timer)

	# Only phase_changed is connected, not round_reset: GameState emits both on a reset,
	# and clearing twice would double-report through `enemies_cleared`.
	GameState.phase_changed.connect(_on_phase_changed)

	# Any enemy already placed in the scene by hand joins the same group, so the reset
	# path owns every enemy on the board rather than just the ones it spawned.
	_adopt_existing_enemies()

	# Points are built on the first physics frame, not here -- see _physics_process.
	set_physics_process(true)


## Waits for the navigation map to synchronise, builds the ring once, then switches
## itself off.
##
## A map query made before the first synchronisation does not merely return a bad answer,
## it fails outright with "query failed because it was made before first map
## synchronization" -- which would leave every perimeter point silently unvalidated.
## Waiting one physics frame is NOT enough; the map's iteration id is the only reliable
## signal that it is ready to answer.
func _physics_process(_delta: float) -> void:
	var map := get_world_3d().navigation_map
	if not map.is_valid() or NavigationServer3D.map_get_iteration_id(map) == 0:
		return
	set_physics_process(false)
	_build_points()
	if GameState.is_action() and _wave == 0:
		_start_waves()
	elif GameState.is_preparation():
		clear_enemies()


## Rebuilds the ring of candidate spawn points. Safe to call again after the layout
## changes -- the navmesh check is what makes a point valid, and that moves with the maze.
func _build_points() -> void:
	_points = PackedVector3Array()
	var area := _area_bounds()
	if area.size == Vector3.ZERO:
		push_warning("[WaveSpawner] no play area found; nothing will spawn")
		return

	var top := area.position.y + area.size.y
	var min_x := area.position.x + perimeter_inset
	var max_x := area.position.x + area.size.x - perimeter_inset
	var min_z := area.position.z + perimeter_inset
	var max_z := area.position.z + area.size.z - perimeter_inset
	if min_x >= max_x or min_z >= max_z:
		push_warning("[WaveSpawner] perimeter_inset larger than the play area")
		return

	var step: float = maxf(perimeter_spacing, 0.5)
	var raw: Array[Vector3] = []
	var x := min_x
	while x <= max_x:
		raw.append(Vector3(x, top, min_z))
		raw.append(Vector3(x, top, max_z))
		x += step
	var z := min_z + step
	while z < max_z:
		raw.append(Vector3(min_x, top, z))
		raw.append(Vector3(max_x, top, z))
		z += step

	var map := get_world_3d().navigation_map
	for point: Vector3 in raw:
		var snapped_point := NavigationServer3D.map_get_closest_point(map, point)
		# An empty map answers every query with the origin; treat that as "no navmesh"
		# and keep the raw ring rather than collapsing every spawn onto (0, 0, 0).
		if snapped_point == Vector3.ZERO:
			_points.append(point)
			continue
		if Vector2(snapped_point.x - point.x, snapped_point.z - point.z).length() > navmesh_tolerance:
			continue
		_points.append(snapped_point)

	if _points.is_empty():
		push_warning("[WaveSpawner] no perimeter point landed on the navmesh")


## World-space bounds of the play surface.
func _area_bounds() -> AABB:
	var node := get_node_or_null(area_path) as Node3D
	if node == null:
		node = get_node_or_null(fallback_area_path) as Node3D
	if node == null:
		return AABB()

	# A StaticBody3D (the navmesh bake surface) carries its size on a box collision shape.
	for child: Node in node.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null:
			continue
		var box := shape_node.shape as BoxShape3D
		if box == null:
			continue
		var centre: Vector3 = node.global_transform * shape_node.position
		return AABB(centre - box.size * 0.5, box.size)

	# CSG level geometry keeps its own size.
	var csg := node as CSGBox3D
	if csg != null:
		return AABB(node.global_position - csg.size * 0.5, csg.size)

	var visual := node as VisualInstance3D
	if visual != null:
		var local := visual.get_aabb()
		return AABB(node.global_transform * local.position, local.size)
	return AABB()


func _on_phase_changed(new_phase: int) -> void:
	_apply_phase(new_phase)


func _apply_phase(new_phase: int) -> void:
	if new_phase == GameState.Phase.ACTION:
		# The Archmage duel is a one-on-one fight. start_boss_fight() enters ACTION
		# to bring the weapons out, and without this guard that would immediately
		# flood the bench with the very minions it just cleared.
		if GameState.boss_fight:
			_timer.stop()
			return
		_start_waves()
		return
	# PREPARATION: stop the clock, rewind to wave 1 and hand the player an empty bench.
	_timer.stop()
	_wave = 0
	clear_enemies()


func _start_waves() -> void:
	if _points.is_empty():
		_build_points()
	_wave = 0
	_timer.wait_time = maxf(wave_interval, 1.0)
	_timer.start()
	_spawn_next_wave()


func _on_wave_timer() -> void:
	if not GameState.is_action():
		_timer.stop()
		return
	_spawn_next_wave()


## Wave 1 brings `first_wave_size`; each wave after that adds `enemies_per_wave`.
func _spawn_next_wave() -> void:
	_wave += 1
	var count: int = first_wave_size + (_wave - 1) * enemies_per_wave
	var live: int = get_tree().get_nodes_in_group(enemy_group).size()
	var room: int = maxi(max_live_enemies - live, 0)
	var spawned := 0
	for i in mini(count, room):
		if _spawn_one() != null:
			spawned += 1
	wave_started.emit(_wave, spawned)


func _spawn_one() -> Node3D:
	if enemy_scene == null or _points.is_empty():
		return null
	var point := _pick_point()
	var enemy := enemy_scene.instantiate() as Node3D
	if enemy == null:
		return null
	# Position BEFORE entering the tree: Enemy._ready() captures its own spawn transform
	# to return to on a reset, so adding first and moving after would record the wrong pose.
	enemy.position = to_local(_ground(point))
	add_child(enemy)
	enemy.add_to_group(enemy_group)
	return enemy


## Picks a perimeter point at least `min_player_distance` from the player. Falls back to
## whichever candidate is furthest away when every roll lands too close, so a player
## standing in the middle of the ring still gets a wave instead of nothing.
func _pick_point() -> Vector3:
	var player := _find_player()
	if player == null:
		return _points[_rng.randi_range(0, _points.size() - 1)]

	var here := player.global_position
	var threshold := min_player_distance * min_player_distance
	for i in max_spawn_attempts:
		var candidate := _points[_rng.randi_range(0, _points.size() - 1)]
		if candidate.distance_squared_to(here) >= threshold:
			return candidate

	var best := _points[0]
	var best_dist := best.distance_squared_to(here)
	for candidate: Vector3 in _points:
		var d := candidate.distance_squared_to(here)
		if d > best_dist:
			best_dist = d
			best = candidate
	return best


## Drops a spawn point onto the actual tabletop. The navmesh bakes a little above the
## surface, and the bench is very slightly tilted, so a fixed height would either bury the
## capsule or drop it from mid-air.
func _ground(point: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		point + Vector3.UP * 3.0, point + Vector3.DOWN * 6.0
	)
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return point
	return hit.position + Vector3.UP * 0.05


func _find_player() -> Node3D:
	for node: Node in get_tree().get_nodes_in_group(player_group):
		var body := node as Node3D
		if body != null:
			return body
	return null


## Enemies placed in the scene by hand still have to obey the reset, so they are pulled
## into the same group the spawned ones use. Found by behaviour rather than node path,
## matching how the weapons and the player locate things.
func _adopt_existing_enemies() -> void:
	var parent := get_parent()
	if parent == null:
		return
	for node: Node in parent.get_children():
		if node == self:
			continue
		if node is CharacterBody3D and node.has_method("is_chasing"):
			node.add_to_group(enemy_group)


## Removes every live enemy. Called on a reset so the player builds in peace.
##
## queue_free() only takes effect at the end of the frame, so a node stays in its group
## after being freed; skipping the already-queued ones keeps a second call in the same
## frame from re-reporting enemies that are already on their way out.
func clear_enemies() -> void:
	var removed := 0
	for node: Node in get_tree().get_nodes_in_group(enemy_group):
		if node.is_queued_for_deletion():
			continue
		node.queue_free()
		removed += 1
	if removed > 0:
		enemies_cleared.emit(removed)


## Current wave number; 0 before the first wave of an attempt.
func current_wave() -> int:
	return _wave


## How many enemies the next wave will try to bring.
func next_wave_size() -> int:
	return first_wave_size + _wave * enemies_per_wave


## How many valid spawn points the ring produced.
func spawn_point_count() -> int:
	return _points.size()
