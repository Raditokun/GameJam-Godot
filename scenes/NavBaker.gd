extends NavigationRegion3D
## Keeps the tabletop navmesh in sync with the clutter the player moves around.
##
## The bench layout is not static -- the whole Preparation Phase is the player
## dragging things into new positions -- so the navmesh has to be re-cut when
## they do. Every body in `watch_group` is watched for movement; once it has
## been still for a moment the mesh is re-baked, and any NavigationObstacle3D
## with `carve_navigation_mesh` on gets punched out of the walkable area.
##
## Re-baking is debounced rather than continuous on purpose: a bake is far too
## expensive to run every frame while an object is being dragged, and there is
## no point re-cutting the mesh for a position the player is about to change
## again. Agent avoidance (RVO) covers the gap in the meantime.

## Bodies in this group are watched for movement. Matches the drag tool's group,
## so anything the player can pick up also re-cuts the navmesh when put down.
@export var watch_group := "draggable"
## How far a body must move, in metres, before the mesh is considered stale.
@export var move_threshold := 1.5
## Seconds a moved body must sit still before the re-bake fires.
@export var settle_time := 0.25
## Floor on the gap between bakes, in seconds.
@export var min_interval := 0.5

## Emitted after a re-bake completes, for debugging and for anything that wants
## to re-path immediately rather than waiting for its own timer.
signal navmesh_rebaked

var _last_positions := {}
var _stale := false
var _still_for := 0.0
var _since_bake := 0.0
var _baking := false


func _ready() -> void:
	if has_signal("bake_finished"):
		bake_finished.connect(_on_bake_finished)
	# First bake happens on the main thread: the enemy asks for a path almost
	# immediately, and a threaded bake would not be ready in time.
	rebake(false)


func _process(delta: float) -> void:
	_since_bake += delta
	if _watch_for_movement():
		_stale = true
		_still_for = 0.0
	elif _stale:
		_still_for += delta
		if _still_for >= settle_time and _since_bake >= min_interval:
			rebake()


## Re-cuts the navigation mesh. Threaded by default so a bake never stalls a
## frame; pass false when the result is needed before the next line runs.
func rebake(threaded: bool = true) -> void:
	if _baking:
		return
	_baking = true
	_stale = false
	_still_for = 0.0
	_since_bake = 0.0
	bake_navigation_mesh(threaded)
	if not threaded:
		_on_bake_finished()


## True if any watched body has moved far enough since it was last sampled.
func _watch_for_movement() -> bool:
	var moved := false
	for node in get_tree().get_nodes_in_group(watch_group):
		var body := node as Node3D
		if body == null:
			continue
		var id := body.get_instance_id()
		var here := body.global_position
		if not _last_positions.has(id):
			_last_positions[id] = here
			continue
		if (_last_positions[id] as Vector3).distance_to(here) > move_threshold:
			_last_positions[id] = here
			moved = true
	return moved


func _on_bake_finished() -> void:
	_baking = false
	navmesh_rebaked.emit()
