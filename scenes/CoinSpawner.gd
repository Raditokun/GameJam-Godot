extends Node3D
## Scatters the round's collectible coins across the bench and owns the progress counter.
##
## Coins are the win condition: collect them all before the waves overwhelm you. They are
## placed in widening rings from the player's start, so the first is a short trip and the
## last is out at the far edge of the desk with the maze in between.
##
## Placement has to survive a bench that is ~500 solid props covering more than half the
## table, so every candidate clears two independent checks:
##   1. it snaps onto the navigation mesh (the player can path to it), and
##   2. a sphere the size of the coin, sitting where the coin will sit, touches nothing
##      (it is not buried inside a crate).
## Checking only the navmesh is not enough -- the carve outlines are 2D footprints, so a
## point can be walkable and still be underneath overhanging geometry.

## The pickup chime. Played through the Player's shared polyphonic SFXPlayer --
## the coin frees itself on collection, so a player of its own would be cut off
## mid-sound. See Player.play_sfx().
const SFX_COIN := preload("res://Sounds/pickupcoin.mp3")

## Emitted on every pickup, with the running count and the target.
signal coin_collected(collected: int, total: int)
## Emitted when the last coin of the round is taken.
signal all_coins_collected

@export_group("Coins")
## Scene instanced for every coin. Must be Coin.tscn.
@export var coin_scene: PackedScene
## How many coins a round places.
@export var coin_count := 10
## Group every live coin joins, so a reset can clear them without node paths.
@export var coin_group := "coins"
## Group identifying the player.
@export var player_group := "player"

@export_group("Placement")
## Node whose bounds define the play surface. Defaults to the navmesh bake surface --
## deliberately not `Floor`, which is ground geometry far below the bench. A plain
## NodePath, not a typed node export, so it resolves without a node_paths= marker.
@export var area_path: NodePath = ^"../Navigation/NavSurface"
## Fallback when `area_path` resolves to nothing.
@export var fallback_area_path: NodePath = ^"../Floor"
## Distance between sampled candidate positions, in metres.
@export var sample_spacing := 4.0
## Keep candidates this far inside the table edge.
@export var edge_inset := 7.0
## A candidate is dropped when the nearest navmesh point is further than this away.
@export var navmesh_tolerance := 2.0
## Radius of the "is this spot empty" overlap test, in metres.
@export var clearance_radius := 0.8
## Height above the floor the clearance sphere sits at. Keeps the tabletop itself out of
## the test, so only real obstructions register.
@export var clearance_height := 1.0
## Minimum gap between two coins, so a band cannot stack them on top of each other.
@export var min_coin_separation := 6.0

@export_group("Distance Scaling")
## No coin spawns closer than this to the player's starting position.
@export var min_player_distance := 12.0

@export_group("UI")
## Label showing "collected/total". Plain NodePath for the same reason as area_path.
@export var counter_label_path: NodePath = ^"../RoundUI/CoinLabel"

var _collected := 0
var _points: PackedVector3Array = PackedVector3Array()
var _ready_for_queries := false


func _ready() -> void:
	if GameSettings.difficulty == GameSettings.Difficulty.EASY:
		coin_count = 5
	else:
		coin_count = 10
	GameState.phase_changed.connect(_on_phase_changed)
	# unbind(1) because boss_fight_started carries the spawned boss and clear_coins()
	# takes no arguments -- connecting them directly does not fail at connect time,
	# it fails at EMIT time with "method expected 0 arguments, but called with 1",
	# which surfaces only when a boss fight actually starts.
	GameState.boss_fight_started.connect(clear_coins.unbind(1))
	# Collecting the tenth coin IS the way into the Archmage duel. Connected from
	# this side because the signal lives here and GameState is an autoload -- the
	# reverse would need GameState to go hunting for a CoinSpawner by node path.
	all_coins_collected.connect(GameState.start_boss_fight)
	# Points are built on the first synchronised physics frame -- see _physics_process.
	set_physics_process(true)
	_update_label()


## Waits for the navigation map to synchronise, then builds the candidate pool once.
##
## A map query before the first synchronisation fails outright rather than returning a
## poor answer, which would leave every candidate unvalidated. One physics frame is not
## enough; the map's iteration id is the only reliable ready signal.
func _physics_process(_delta: float) -> void:
	var map := get_world_3d().navigation_map
	if not map.is_valid() or NavigationServer3D.map_get_iteration_id(map) == 0:
		return
	set_physics_process(false)
	_ready_for_queries = true
	# Candidates are NOT built here. The map reports itself synchronised a frame or two
	# before NavBaker's region is actually registered in it, so a build this early finds
	# nothing. _apply_phase rebuilds on every ACTION anyway, which is the only moment the
	# list is needed and the only moment it is guaranteed current.
	_apply_phase(GameState.phase)


## Samples the play surface on a grid and keeps the positions a coin can legitimately
## occupy. Called again whenever a round starts, so a maze rebuilt during PREPARATION is
## taken into account.
func _build_candidates() -> void:
	_points = PackedVector3Array()
	var area := _area_bounds()
	if area.size == Vector3.ZERO:
		push_warning("[CoinSpawner] no play area found; no coins will spawn")
		return

	var top := area.position.y + area.size.y
	var min_x := area.position.x + edge_inset
	var max_x := area.position.x + area.size.x - edge_inset
	var min_z := area.position.z + edge_inset
	var max_z := area.position.z + area.size.z - edge_inset
	var step: float = maxf(sample_spacing, 1.0)
	var map := get_world_3d().navigation_map
	var space := get_world_3d().direct_space_state

	var probe := SphereShape3D.new()
	probe.radius = clearance_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = probe
	query.collision_mask = 1

	var x := min_x
	while x <= max_x:
		var z := min_z
		while z <= max_z:
			var candidate := Vector3(x, top, z)
			var snapped_point := NavigationServer3D.map_get_closest_point(map, candidate)
			if snapped_point == Vector3.ZERO:
				z += step
				continue
			if Vector2(
				snapped_point.x - candidate.x, snapped_point.z - candidate.z
			).length() > navmesh_tolerance:
				z += step
				continue
			var grounded := _ground(snapped_point)
			# The coin has to fit where it lands. The sphere sits above the floor so the
			# tabletop never counts as an obstruction, only props do.
			query.transform = Transform3D(
				Basis.IDENTITY, grounded + Vector3.UP * clearance_height
			)
			if space.intersect_shape(query, 1).is_empty():
				_points.append(grounded)
			z += step
		x += step

	if _points.is_empty():
		push_warning("[CoinSpawner] no clear, reachable spot found for coins")


## World-space bounds of the play surface. Handles a box collision shape (the navmesh
## bake surface), a CSGBox3D, or any VisualInstance3D.
func _area_bounds() -> AABB:
	var node := get_node_or_null(area_path) as Node3D
	if node == null:
		node = get_node_or_null(fallback_area_path) as Node3D
	if node == null:
		return AABB()

	for child: Node in node.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null:
			continue
		var box := shape_node.shape as BoxShape3D
		if box == null:
			continue
		var centre: Vector3 = node.global_transform * shape_node.position
		return AABB(centre - box.size * 0.5, box.size)

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
	# The Archmage duel is not a collect-a-thon. start_boss_fight() enters ACTION to
	# bring the weapons out, and without this the coins would scatter across the
	# arena and the counter would sit on the HUD through the whole fight.
	if GameState.boss_fight:
		clear_coins()
		return

	if new_phase == GameState.Phase.ACTION:
		if not _ready_for_queries:
			return
		# clear_coins() also rewinds the counter and hides it; the readout goes back
		# up at the end of this branch once the new coins exist.
		clear_coins()
		# Rebuild first: the player has just finished rearranging the maze, so last
		# round's candidate list may now be buried or unreachable.
		_build_candidates()
		_spawn_coins()
		_update_label()
		_set_counter_visible(true)
		return

	# PREPARATION: empty the board and hide the counter.
	clear_coins()


## Places `coin_count` coins in widening distance bands from the player.
##
## Candidates are sorted by distance and split into equal-sized bands, one coin drawn per
## band. That is what makes the set progressive: band 0 holds the nearest legal spots and
## the last band the far edge of the desk, rather than ten coins landing in a clump.
func _spawn_coins() -> void:
	if coin_scene == null or _points.is_empty():
		return

	var origin := _player_position()
	var pool: Array[Vector3] = []
	for point: Vector3 in _points:
		if point.distance_to(origin) >= min_player_distance:
			pool.append(point)
	if pool.is_empty():
		push_warning("[CoinSpawner] every candidate is inside min_player_distance")
		return
	pool.sort_custom(
		func(a: Vector3, b: Vector3) -> bool:
			return a.distance_squared_to(origin) < b.distance_squared_to(origin)
	)

	# Bands are cut by DISTANCE, not by index. Splitting the sorted pool into equal-sized
	# index slices sounds equivalent but is not: candidates cluster wherever the bench is
	# open, so a sparse near-region stretches band 0 across a huge distance range and the
	# "nearest" coin can land most of a table away. Slicing the distance span keeps the
	# ladder even from min_player_distance out to the far edge.
	var near: float = pool[0].distance_to(origin)
	var far: float = pool[pool.size() - 1].distance_to(origin)
	var span: float = maxf(far - near, 0.001)
	var placed: Array[Vector3] = []
	for i in coin_count:
		var lo: float = near + span * (float(i) / float(coin_count))
		var hi: float = near + span * (float(i + 1) / float(coin_count))
		var chosen: Variant = _draw_in_band(pool, origin, lo, hi, placed)
		if chosen == null:
			continue
		var spot: Vector3 = chosen
		placed.append(spot)
		_place_coin(spot)


## Picks a random point whose distance from `origin` falls in [lo, hi] and which is not
## too near an already-placed coin, widening to the whole pool if the band is empty.
func _draw_in_band(
	pool: Array[Vector3], origin: Vector3, lo: float, hi: float, placed: Array[Vector3]
) -> Variant:
	var band: Array[Vector3] = []
	for point: Vector3 in pool:
		var d := point.distance_to(origin)
		if d >= lo and d <= hi:
			band.append(point)
	band.shuffle()
	for point: Vector3 in band:
		if _is_clear_of(point, placed):
			return point
	for point: Vector3 in pool:
		if _is_clear_of(point, placed):
			return point
	return null


func _is_clear_of(point: Vector3, placed: Array[Vector3]) -> bool:
	for other: Vector3 in placed:
		if point.distance_to(other) < min_coin_separation:
			return false
	return true


func _place_coin(spot: Vector3) -> void:
	var coin := coin_scene.instantiate() as Node3D
	if coin == null:
		return
	coin.position = to_local(spot)
	add_child(coin)
	if not coin.is_in_group(coin_group):
		coin.add_to_group(coin_group)
	if coin.has_signal("collected"):
		coin.collected.connect(_on_coin_collected)


func _on_coin_collected(_coin: Node3D) -> void:
	_collected += 1
	_play_sfx(SFX_COIN)
	_update_label()
	coin_collected.emit(_collected, coin_count)
	if _collected >= coin_count:
		all_coins_collected.emit()


## Hands a sound to the Player's shared mixer. Found by GROUP, not node path --
## the spawner sits in Main.tscn and the mixer inside Player.tscn, so there is no
## stable path between them; `player_group` is the same handle _player_position()
## already uses.
func _play_sfx(stream: AudioStream) -> void:
	for node: Node in get_tree().get_nodes_in_group(player_group):
		if node.has_method("play_sfx"):
			node.play_sfx(stream)
			return


## Drops a point onto the actual tabletop. The navmesh bakes a little above the surface
## and the bench is slightly tilted, so a fixed height would float or bury the coin.
func _ground(point: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		point + Vector3.UP * 3.0, point + Vector3.DOWN * 6.0
	)
	query.collision_mask = 1
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return point
	return hit.position


func _player_position() -> Vector3:
	for node: Node in get_tree().get_nodes_in_group(player_group):
		var body := node as Node3D
		if body != null:
			return body.global_position
	return global_position


## Wipes the collectible round: removes every uncollected coin, rewinds the counter and
## takes the readout off the HUD.
##
## Skips nodes already queued for deletion, because a freed node stays in its group until
## the end of the frame and would otherwise be freed twice.
##
## Safe to call repeatedly -- the boss fight reaches this by two routes (the phase change
## and `boss_fight_started`) and both firing is fine.
func clear_coins() -> void:
	for node: Node in get_tree().get_nodes_in_group(coin_group):
		if node.is_queued_for_deletion():
			continue
		node.queue_free()
	_collected = 0
	_update_label()
	_set_counter_visible(false)


func _update_label() -> void:
	var label := get_node_or_null(counter_label_path) as Label
	if label == null:
		return
	label.text = "COINS  %d/%d" % [_collected, coin_count]


func _set_counter_visible(shown: bool) -> void:
	var label := get_node_or_null(counter_label_path) as Label
	if label != null:
		label.visible = shown


## How many coins the player has taken this round.
func collected_count() -> int:
	return _collected


## How many candidate positions passed the navmesh and clearance checks.
func candidate_count() -> int:
	return _points.size()
