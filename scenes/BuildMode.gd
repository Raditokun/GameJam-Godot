extends Node3D
## Preparation-phase build controller: grab an obstacle, fly it around on the
## crosshair, spin it, drop it. Freeform by design -- no grid, no snapping, no
## legal-placement rules. The player's whole job in this phase is imposing
## their own Order on the clutter, so the tool must never impose one for them.
##
## Lives as a child of Player and reads input itself, the same way the weapons
## do; the Player only decides which phase is running. The camera is reached by
## node path rather than an exported NodePath on purpose -- exported node refs
## in a hand-edited .tscn silently resolve to null unless the [node] line
## carries a node_paths= marker, and this scene is hand-edited.

## How far the placement ray reaches, in metres. The workbench is enormous from
## a miniature's point of view, so this is much longer than a normal use range.
@export var build_reach := 45.0
## Degrees of yaw per mouse-wheel notch while an obstacle is held.
@export var rotate_step_deg := 15.0
## How quickly a held obstacle catches up to the crosshair, in 1/seconds.
## Instant placement feels jittery at this scale; a short lag reads as weight.
@export var follow_speed := 18.0
## Seconds between the pick-up and the piece being droppable, so a single fast
## click cannot grab and immediately re-drop the same obstacle.
@export var grab_debounce := 0.12

@onready var camera: Camera3D = get_node("../Head/Camera3D")

var _held: Obstacle = null
var _hovered: Obstacle = null
var _held_yaw := 0.0
var _held_layer := 1
var _held_mask := 1
var _since_grab := 0.0
# Where the held obstacle is being asked to sit. Kept separate from its actual
# position so follow_speed can ease it there.
var _target_position := Vector3.ZERO


func _process(delta: float) -> void:
	if not GameState.is_preparation():
		# Locking in mid-drag would strand the piece inside the player.
		if _held != null:
			_drop()
		_set_hovered(null)
		return

	_since_grab += delta
	if _held != null:
		_update_held(delta)
	else:
		_update_hover()

	if Input.is_action_just_pressed("fire"):
		if _held != null and _since_grab >= grab_debounce:
			_drop()
		elif _held == null:
			_grab()


func _unhandled_input(event: InputEvent) -> void:
	if _held == null or not GameState.is_preparation():
		return
	# The wheel spins the held piece. In PREPARATION the weapons are holstered,
	# so borrowing the slot-cycling wheel actions costs nothing.
	if event.is_action_pressed("slot_next"):
		_held_yaw -= deg_to_rad(rotate_step_deg)
	elif event.is_action_pressed("slot_prev"):
		_held_yaw += deg_to_rad(rotate_step_deg)


## Fires a ray down the crosshair and reports what it hit, or an empty dict.
## The player and (when held) the dragged obstacle are excluded so the piece
## can never land on itself.
func _aim() -> Dictionary:
	var player := get_parent() as CollisionObject3D
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from - camera.global_basis.z * build_reach)
	var skip: Array[RID] = []
	if player != null:
		skip.append(player.get_rid())
	if _held != null:
		skip.append(_held.get_rid())
	query.exclude = skip
	return get_world_3d().direct_space_state.intersect_ray(query)


## Lights up whatever obstacle the crosshair is resting on.
func _update_hover() -> void:
	var hit := _aim()
	_set_hovered(null if hit.is_empty() else hit["collider"] as Obstacle)


func _set_hovered(obstacle: Obstacle) -> void:
	if _hovered == obstacle:
		return
	if _hovered != null and is_instance_valid(_hovered) and not _hovered.held:
		_hovered.set_highlighted(false)
	_hovered = obstacle
	if _hovered != null:
		_hovered.set_highlighted(true)


func _grab() -> void:
	var hit := _aim()
	if hit.is_empty():
		return
	var obstacle := hit["collider"] as Obstacle
	if obstacle == null:
		return

	_set_hovered(null)
	_held = obstacle
	_since_grab = 0.0
	_held_yaw = obstacle.global_rotation.y
	# Remember the real collision setup: grab() zeroes it so the piece can fly
	# through the clutter, and the exact values have to come back on release.
	_held_layer = obstacle.collision_layer
	_held_mask = obstacle.collision_mask
	_target_position = obstacle.global_position
	obstacle.grab()


func _drop() -> void:
	if _held == null:
		return
	if is_instance_valid(_held):
		_held.release(_held_layer, _held_mask)
	_held = null


## Seats the held obstacle on whatever surface the crosshair is over, keeping
## it upright and applying the wheel's yaw. If the ray hits nothing (aimed off
## the edge of the bench) the piece hangs at arm's length instead of teleporting
## to the horizon.
func _update_held(delta: float) -> void:
	if not is_instance_valid(_held):
		_held = null
		return

	var hit := _aim()
	if hit.is_empty():
		_target_position = camera.global_position - camera.global_basis.z * build_reach
	else:
		var point := hit["position"] as Vector3
		# Aiming at the SIDE of something (another block, the table's edge) must
		# not leave the piece hanging halfway up that face -- drop it to whatever
		# surface is underneath the aim point instead.
		if (hit["normal"] as Vector3).dot(Vector3.UP) < 0.7:
			point = _ground_below(point)
		# Lift the piece by half its height so it rests ON the surface rather
		# than being buried to its centre in the tabletop.
		_target_position = point + Vector3.UP * _held.base_offset()

	_held.global_position = _held.global_position.lerp(
		_target_position, clampf(follow_speed * delta, 0.0, 1.0)
	)
	# Upright always: obstacles are walls in a maze, and a tipped wall is a ramp.
	_held.global_rotation = Vector3(0.0, _held_yaw, 0.0)


## Finds the surface under `point` by dropping a ray from just above it. Used
## when the crosshair lands on a vertical face, so the piece settles on the
## bench instead of clinging to the side of whatever was aimed at.
func _ground_below(point: Vector3) -> Vector3:
	var player := get_parent() as CollisionObject3D
	var query := PhysicsRayQueryParameters3D.create(
		point + Vector3.UP * 0.5, point + Vector3.DOWN * build_reach
	)
	var skip: Array[RID] = []
	if player != null:
		skip.append(player.get_rid())
	if _held != null:
		skip.append(_held.get_rid())
	query.exclude = skip
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return point if hit.is_empty() else hit["position"] as Vector3
